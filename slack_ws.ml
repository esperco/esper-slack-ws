
open Lwt
open Log

(*
   - open websocket
   - post to elb
   - save timestamp of latest event
   - update socket connection
*)

(*
let connections = Hashtbl.create 10
*)

let react input_handler send frame =
  let open Websocket_lwt.Frame in
  match frame.opcode with
  | Opcode.Ping ->
      send (Websocket_lwt.Frame.create ~opcode:Opcode.Pong ()) >>= fun () ->
      return true

  | Opcode.Close ->
      (* Immediately echo and pass this last message to the user *)
      (if String.length frame.content >= 2 then
         send (
           Websocket_lwt.Frame.create ~opcode:Opcode.Close
             ~content:(String.sub frame.content 0 2) ()
         )
       else
         send (Websocket_lwt.Frame.close 1000)
      ) >>= fun () ->
      return false

  | Opcode.Pong ->
      return true

  | Opcode.Text
  | Opcode.Binary ->
      input_handler frame.content >>= fun () ->
      return true

  | Opcode.Continuation
  | Opcode.Ctrl _
  | Opcode.Nonctrl _ ->
      send (Websocket_lwt.Frame.close 1002) >>= fun () ->
      return false

let create_websocket_connection ws_url input_handler =
  let open Websocket_lwt.Frame in
  let uri = Uri.of_string ws_url in
  Resolver_lwt.resolve_uri ~uri Resolver_lwt_unix.system >>= fun endp ->
  let ctx = Conduit_lwt_unix.default_ctx in
  Conduit_lwt_unix.endp_to_client ~ctx endp >>= fun client ->
  Websocket_lwt.with_connection ~ctx client uri >>= fun (recv, send) ->

  let rec loop () =
    recv () >>= fun frame ->
    react input_handler send frame >>= function
    | true -> loop ()
    | false -> return ()
  in
  let close () =
    logf `Info "Sending a close frame.";
    send (Websocket_lwt.Frame.close 1000)
  in
  let push content =
    send (Websocket_lwt.Frame.create ~content ())
  in
  async loop;
  return (push, close)

let create_connection slack_teamid input_handler =
  Slack.get_auth slack_teamid >>= function
  | None ->
      logf `Error "Cannot connect to Slack for team %s"
        (Slack_api_teamid.to_string slack_teamid);
      return ()
  | Some auth ->
      Slack_api.rtm_start auth.Slack_api_t.access_token >>= fun x ->
      let ws_url = x.Slack_api_t.url in
      create_websocket_connection ws_url input_handler >>= fun (push, close) ->
      return ()

let init () =
  return ()
