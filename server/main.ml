(* Copyright (C) 2025, Thomas Leonard
 * See the README file for details. *)

open Lwt.Infix

let src = Logs.Src.create "cuekeeper-server" ~doc:"CueKeeper server"
module Log = (val Logs.src_log src : Logs.LOG)

let port = 8443

module No_sync (G : Git.S) = struct
  (* We don't use Git's sync, but it requires us to provide this module anyway.
     From [Irmin_git], but not exposed. *)

  type hash = G.hash
  type store = G.t

  type error =
    [ `Not_found | `Msg of string | `Exn of exn | `Cycle | `Invalid_flow ]

  let pp_error _ _ = assert false

  let fetch ?push_stdout:_ ?push_stderr:_ ?threads:_ ~ctx:_ _ _ ?version:_
      ?capabilities:_ ?deepen:_ _ =
    assert false

  let push ~ctx:_ _ _ ?version:_ ?capabilities:_ _ = assert false
end

module Store = Irmin_git.Make(Irmin_git.Mem)(No_sync(Irmin_git.Mem))
    (Irmin.Contents.String)(Irmin.Path.String_list)(Irmin.Branch.String)

module Http_server = Cohttp_lwt_unix.Server

module Server = Server.Make(Store)(Http_server)

(* We store the hash rather than the original to avoid storing the secret. *)
let user_of_token devices token =
  let hashed = Digestif.SHA256.digest_string token |> Digestif.SHA256.to_hex in
  let device = Devices.lookup devices hashed in
  if device = None then Log.warn (fun f -> f "Invalid access token used (hash = %S)" hashed);
  device

let handle_request ~server ~devices s conn_id request body =
  (* Instead of handing the Git store directly to [Server.handle_request], wrap it in a function
   * that authenticates the request first, so it can't use it without checking. *)
  let get_db () =
    let uri = Cohttp.Request.uri request in
    match Uri.get_query_param uri "token" with
    | None -> Error (Http_server.respond_error ~status:`Bad_request ~body:"Missing access token" ())
    | Some token ->
      match user_of_token devices token with
      | None -> Error (Http_server.respond_error ~status:`Unauthorized ~body:"Invalid access token" ())
      | Some user ->
        Log.info (fun f -> f "Handling request for %S" user);
        Ok s in
  Server.handle_request server get_db conn_id request body

let main devices_file static_files tls_dir =
  let devices = Devices.of_file devices_file in
  let server = Server.make ~static_files in
  Lwt_main.run begin
    Store.Repo.v (Irmin_mem.config ()) >>= Store.master >>= fun s ->
    let mode =
      `TLS (
        `Crt_file_path (Filename.concat tls_dir "server.pem"),
        `Key_file_path (Filename.concat tls_dir "server.key"), `No_password,
        `Port port
      )
    in
    Log.app (fun f -> f "Server available at https://127.0.0.1:%d" port);
    Http_server.create ~mode (Http_server.make ~callback:(handle_request ~server ~devices s) ())
  end

open Cmdliner

let ( $ ) = Term.( $ )

let devices =
  let doc = "List of devices, one per line in the form: SHA1 LABEL" in
  Arg.(required @@ opt (some file) None @@ info ["devices"] ~docv:"DEVICES" ~doc)

let static_files =
  let doc = "Directory with the JavaScript and other resources" in
  Arg.(value @@ opt dir "_build/static" @@ info ["static-files"] ~docv:"DIR" ~doc)

let tls_config =
  let doc = "Directory with the server.pem" in
  Arg.(value @@ opt dir "server/conf" @@ info ["tls-config"] ~docv:"DIR" ~doc)

let cmd = Term.const main $ devices $ static_files $ tls_config

let () =
  Logs.set_level (Some Info);
  Logs.set_reporter (Logs_fmt.reporter ());
  let info = Cmd.info "cuekeeper" in
  exit (Cmd.eval @@ Cmd.v info cmd)
