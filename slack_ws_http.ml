(*
   HTTP server that receives notifications from the API servers,
   about updates concerning Slack channels to watch.
*)

open Lwt
open Cohttp
open Cohttp_lwt_unix

let server =
  let callback _conn req body =
    let uri = Uri.to_string (Request.uri req) in
    let method_ = Code.string_of_method (Request.meth req) in
    let headers = Header.to_string (Request.headers req) in
    body |> Cohttp_lwt_body.to_string >|= (fun body ->
      (Printf.sprintf "Uri: %s\nMethod: %s\nHeaders\nHeaders: %s\nBody: %s"
         uri meth headers body))
    >>= (fun body -> Server.respond_string ~status:`OK ~body ())
  in
  let port = (Conf.get()).Conf_t.slack_ws_port in
  Server.create ~mode:(`TCP (`Port port)) (Server.make ~callback ())

let main () = ignore (Lwt_main.run server)
