open Lwt.Infix

module Hash = Digestif.SHA1

let ( / ) = Filename.concat
let ( >>!= ) = Lwt_result.bind

let state_dir = Sys.getcwd () / "var"
let repos_dir = state_dir / "git"

let dir_exists d =
  match Unix.lstat d with
  | Unix.{ st_kind = S_DIR; _ } -> true
  | _ -> false
  | exception Unix.Unix_error(Unix.ENOENT, _, _) -> false

let ensure_dir path =
  if not (dir_exists path) then Unix.mkdir path 0o700

let get_tmp_dir () =
  ensure_dir state_dir;
  let tmp = state_dir / "tmp" in
  ensure_dir tmp;
  tmp

module Repo = struct
  type t = {
    url : Uri.t;
    lock : Lwt_mutex.t;
  }

  let id t =
    let base = Filename.basename (Uri.path t.url) in
    let digest = Hash.digest_string (Uri.to_string t.url) in
    Fmt.strf "%s-%s" base (Hash.to_hex digest)

  let local_copy t =
    repos_dir / id t

  let v url =
    let url = Uri.of_string url in
    match Uri.scheme url with
    | Some "git" | Some "http" | Some "https" -> { url; lock = Lwt_mutex.create () }
    | Some x -> Fmt.failwith "Unsupported scheme %S in URL %a" x Uri.pp url
    | None -> Fmt.failwith "Missing scheme in URL %a" Uri.pp url

  let has_commits t cs =
    let local_repo = local_copy t in
    if dir_exists local_repo then (
      let rec aux = function
        | [] -> Lwt_result.return true
        | c :: cs ->
          Lwt_process.exec ~cwd:local_repo ("", [| "git"; "cat-file"; "-e"; Hash.to_hex c |]) >>= function
          | Unix.WEXITED 0 -> aux cs
          | Unix.WEXITED _ -> Lwt_result.return false
          | _ -> Fmt.failwith "git cat-file crashed!"
      in
      aux cs
    ) else Lwt_result.return false      (* Don't let ocaml-git try to init a new repository! *)

  let fetch ~switch ~log t =
    let local_repo = local_copy t in
    begin
      if dir_exists local_repo then Lwt_result.return ()
      else (
        Lwt_switch.with_switch @@ fun switch -> (* Don't let the user cancel these two. *)
        Process.exec ~switch ~log ["git"; "init"; local_repo] >>!= fun () ->
        Process.exec ~switch ~log ["git"; "-C"; local_repo; "remote"; "add"; "origin"; "--mirror=fetch"; "--"; Uri.to_string t.url]
      )
    end >>!= fun () ->
    Process.exec ~switch ~log ["git"; "-C"; local_repo; "fetch"; "-q"; "--update-head-ok"; "origin"]
end

let repos = Hashtbl.create 1000

let repo url =
  match Hashtbl.find_opt repos url with
  | Some x -> x
  | None ->
    let repo = Repo.v url in
    Hashtbl.add repos url repo;
    repo

let rec lwt_result_list_iter_s f = function
  | [] -> Lwt_result.return ()
  | x :: xs ->
    f x >>!= fun () ->
    lwt_result_list_iter_s f xs

let build_context ~switch ~log ~tmpdir descr =
  match Cluster_api.Raw.Reader.JobDescr.commits_get_list descr |> List.map Hash.of_hex with
  | [] ->
    Lwt_result.return ()
  | (c :: cs) as commits ->
    let repository = repo (Cluster_api.Raw.Reader.JobDescr.repository_get descr) in
    Lwt_mutex.with_lock repository.lock (fun () ->
        begin
          Repo.has_commits repository commits >>!= function
          | true -> Log_data.info log "All commits already cached"; Lwt_result.return ()
          | false -> Repo.fetch ~switch ~log repository
        end >>!= fun () ->
        let clone = Repo.local_copy repository in
        Process.exec ~switch ~log ["git"; "-C"; clone; "reset"; "--hard"; Hash.to_hex c] >>!= fun () ->
        Process.exec ~switch ~log ["git"; "-C"; clone; "clean"; "-fdx"] >>!= fun () ->
        let merge c = Process.exec ~switch ~log ["git"; "-C"; clone; "merge"; Hash.to_hex c] in
        cs |> lwt_result_list_iter_s merge >>!= fun () ->
        Process.exec ~switch ~log ["git"; "-C"; clone; "submodule"; "init"] >>!= fun () ->
        Process.exec ~switch ~log ["git"; "-C"; clone; "submodule"; "update"] >>!= fun () ->
        Sys.readdir clone |> Array.iter (function
            | ".git" -> ()
            | name -> Unix.rename (clone / name) (tmpdir / name)
          );
        (* Maybe we could remove this at some point, or make it optional, but
           the base image builder needs it for now: *)
        Process.exec ~switch ~log ["cp"; "-a"; clone / ".git"; tmpdir / ".git"] >>!= fun () ->
        Lwt_result.return ()
      )

let with_build_context ~switch ~log descr fn =
  let tmp = get_tmp_dir () in
  Lwt_io.with_temp_dir ~parent:tmp ~prefix:"build-context-" @@ fun tmpdir ->
  build_context ~switch ~log ~tmpdir descr >>!= fun () ->
  fn tmpdir
