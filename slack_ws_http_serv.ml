(*
   HTTP server that receives notifications from the API servers,
   about updates concerning Slack channels to watch.
*)

open Printf
open Lwt
open Log

let handle_request path method_ req_body =
  match path with
  | "/echo" -> return (`OK, req_body)
  | _ -> return (`Not_found, "Not found")

let create_server () =
  let callback _conn req body =
    catch
      (fun () ->
         let uri = Cohttp.Request.uri req in
         let method_ = Cohttp.Request.meth req in
         Cohttp_lwt_body.to_string body >>= fun req_body ->
         handle_request (Uri.path uri) method_ req_body
      )
      (fun e ->
         let exn_info = Log.string_of_exn e in
         let error_id = Util_exn.trace_hash e in
         let resp_body = sprintf "Internal error #%s" error_id in
         let error_msg = sprintf "Internal error #%s: %s" error_id exn_info in
         logf `Error "%s" error_msg;
         Apputil_error.report_error error_id error_msg >>= fun () ->
         return (`Internal_server_error, resp_body)
      )
    >>= fun (resp_status, resp_body) ->
    Cohttp_lwt_unix.Server.respond_string
      ~status:resp_status ~body:resp_body ()
  in
  let port = (Conf.get ()).Conf_t.slack_ws_port in
  Cohttp_lwt_unix.Server.create ~mode:(`TCP (`Port port))
    (Cohttp_lwt_unix.Server.make ~callback ())
