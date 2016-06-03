(*
   Handler for incoming events:
   - respond to json pings
   - forward other incoming events to our http server
*)

open Slack_ws_t
open Slack_ws_conn
(*
let make_input_handler forward =
  fun send event_json ->
    match parse_event event_json with
    | Pong ->
        (match !waiting_for_pong with
         | None -> ()
         | Some (_, awakener) ->
             waiting_for_pong := None;
             Lwt.wakeup awakener ()
        )
    | Forward event_json ->
        forward event_json
*)
