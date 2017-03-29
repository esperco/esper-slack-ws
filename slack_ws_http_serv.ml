(*
   HTTP server that receives notifications from the API servers,
   about updates concerning Slack channels to watch.
*)

open Printf
open Lwt
open Log

let split_path s =
  match Pcre.split ~pat:"/" s with
  | "" :: l
  | l -> l

let blame_client f x =
  try f x
  with _ -> Http_exn.bad_request `Bad_request "Bad request"

let handle_request path method_ req_body =
  match split_path path with
  | ["echo"] ->
      return (`OK, req_body)
  | ["watch"; esper_teamid] ->
      let esper_teamid = blame_client Teamid.of_string esper_teamid in
      User_team.get esper_teamid >>= fun team ->
      Slack_ws.connect_team team.Api_t.team_executive >>= fun () ->
      return (`OK, "OK")
  | _ ->
      return (`Not_found, "Not found")

let handle_exception e =
  match Trax.unwrap e with
  | Http_exn.Bad_request error ->
      let body = Api_j.string_of_client_error error in
      return (`Bad_request, body)
  | e ->
      let exn_info = Log.string_of_exn e in
      let error_id = Util_exn.trace_hash e in
      let resp_body = sprintf "Internal error #%s" error_id in
      let error_msg = sprintf "Internal error #%s: %s" error_id exn_info in
      Apputil_error.report_error error_id error_msg >>= fun () ->
      return (`Internal_server_error, resp_body)

let create_server () =
  let callback _conn req body =
    catch
      (fun () ->
         let uri = Cohttp.Request.uri req in
         let method_ = Cohttp.Request.meth req in
         Cohttp_lwt_body.to_string body >>= fun req_body ->
         handle_request (Uri.path uri) method_ req_body
      )
      handle_exception
    >>= fun (resp_status, resp_body) ->
    Cohttp_lwt_unix.Server.respond_string
      ~status:resp_status ~body:resp_body ()
  in
  let port = (Conf.get ()).Conf_t.slack_ws_port in
  Cohttp_lwt_unix.Server.create ~mode:(`TCP (`Port port))
    (Cohttp_lwt_unix.Server.make ~callback ())
