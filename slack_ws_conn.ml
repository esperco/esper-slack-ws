
open Lwt
open Log

let ( >>=! ) = Lwt.bind

(*
   - open websocket
   - post to elb
   - save timestamp of latest event
   - update socket connection
*)

module Frame = Websocket_lwt.Frame
module Opcode = Websocket_lwt.Frame.Opcode

type send = Frame.t -> unit Lwt.t

type connection = {
  conn_id: Slack_api_teamid.t;
  send: Frame.t -> unit Lwt.t;
  mutable waiting_for_pong: (bool Lwt.t * unit Lwt.u) option ref;
}

let connections = Hashtbl.create 10

let is_json_pong s =
  try
    (Slack_ws_j.type_only_of_string s).Slack_ws_j.type_ = "pong"
  with _ ->
    false

(* Warning: Slack doesn't respond to standard ping frames *)
let ping (send: send) =
  logf `Info "WS send ping";
  send (Frame.create ~opcode:(Frame.Opcode.Ping) ())

let pong (send: send) =
  logf `Info "WS send pong";
  send (Frame.create ~opcode:Frame.Opcode.Pong ())

let push (send: send) content =
  logf `Info "WS send content %S" content;
  send (Frame.create ~content ())

let close (send: send) =
  logf `Info "WS send close";
  send (Frame.close 1000 (* normal closure *))

let remove_connection id =
  try
    let {send} = Hashtbl.find connections id in
    Hashtbl.remove connections id;
    catch
      (fun () -> close send)
      (fun e ->
         logf `Error "Can't close websocket connection: %s" (string_of_exn e);
         return ()
      )
  with Not_found ->
    return ()

let replace_connection x =
  async (fun () -> remove_connection x.conn_id);
  Hashtbl.add connections x.conn_id x

let react input_handler waiting_for_pong send frame =
  match frame.Frame.opcode with
  | Opcode.Ping ->
      logf `Debug "Slack WS received Ping";
      pong send

  | Opcode.Close ->
      logf `Debug "Slack WS received Close";
      if String.length frame.Frame.content >= 2 then
        send (
          Frame.create ~opcode:Opcode.Close
            ~content:(String.sub frame.Frame.content 0 2) ()
        )
      else
        close send

  | Opcode.Pong ->
      logf `Debug "Slack WS received Pong";
      return ()

  | Opcode.Text
  | Opcode.Binary ->
      let content = frame.Frame.content in
      logf `Debug "Slack WS received content: %S" content;
      if is_json_pong content then (
        (match !waiting_for_pong with
         | None -> ()
         | Some (_, awakener) ->
             waiting_for_pong := None;
             Lwt.wakeup awakener ()
        );
        return ()
      )
      else
        input_handler send frame.Frame.content >>= fun () ->
        return ()

  | Opcode.Continuation
  | Opcode.Ctrl _
  | Opcode.Nonctrl _ ->
      logf `Debug "Slack WS received Continuation, Ctrl, or Nonctrl";
      send (Frame.close 1002 (* protocol error *))

let create_websocket_connection ws_url input_handler waiting_for_pong =
  let orig_uri = Uri.of_string ws_url in
  let uri = Uri.with_scheme orig_uri (Some "https") in
  Resolver_lwt.resolve_uri ~uri Resolver_lwt_unix.system >>= fun endp ->
  let ctx = Conduit_lwt_unix.default_ctx in
  Conduit_lwt_unix.endp_to_client ~ctx endp >>= fun client ->
  Websocket_lwt.with_connection ~ctx client uri >>= fun (recv, send) ->

  let frame_stream = Websocket_lwt.mk_frame_stream recv in
  let loop () =
    Apputil_error.catch_report_ignore "Slack websocket"
      (fun () ->
         Lwt_stream.iter_s (fun frame ->
           react input_handler waiting_for_pong send frame
         ) frame_stream
      )
  in
  async loop;
  return send

let create_connection slack_teamid input_handler =
  Slack.get_auth slack_teamid >>= function
  | None ->
      logf `Error "Cannot connect to Slack for team %s"
        (Slack_api_teamid.to_string slack_teamid);
      Http_exn.bad_request
        `Slack_authentication_missing
        "Slack authentication missing"
  | Some auth ->
      Slack_api.rtm_start auth.Slack_api_t.access_token >>= fun x ->
      let ws_url = x.Slack_api_t.url in
      let waiting_for_pong = ref None in
      create_websocket_connection ws_url
        input_handler waiting_for_pong >>= fun send ->
      let conn = {
        conn_id = slack_teamid;
        send;
        waiting_for_pong;
      } in
      return conn

let get_connection slack_teamid =
   try Some (Hashtbl.find connections slack_teamid)
   with Not_found -> None

let obtain_connection slack_teamid create_input_handler =
  let mutex_key = "slack-ws:" ^ Slack_api_teamid.to_string slack_teamid in
  Redis_mutex.with_mutex ~atime:30. ~ltime:60 mutex_key (fun () ->
    match get_connection slack_teamid with
    | Some x -> return x
    | None ->
        let input_handler = create_input_handler () in
        create_connection slack_teamid input_handler >>= fun conn ->
        replace_connection conn;
        return conn
  )

(*
   Send a json ping and wait for a json pong response for up to 10 seconds.
   (standard ping requests are not honored by Slack)
*)
let check_connection conn =
  match !(conn.waiting_for_pong) with
  | Some (result, _) ->
      result
  | None ->
      Apputil_error.catch_and_report "Slack Websocket ping"
        (fun () ->
           let waiter, awakener = Lwt.wait () in
           let success = waiter >>= fun () -> return true in
           let failure = Lwt_unix.sleep 10. >>= fun () -> return false in
           let result = Lwt.pick [success; failure] in
           conn.waiting_for_pong := Some (result, awakener);
           push conn.send "{\"id\":0,\"type\":\"ping\"}" >>= fun () ->
           result
        )
        (fun e ->
           logf `Error "Websocket ping error: %s" (string_of_exn e);
           return false
        )
      >>= function
      | true ->
          return true
      | false ->
          logf `Error "Websocket %s didn't respond to ping request"
            (Slack_api_teamid.to_string conn.conn_id);
          remove_connection conn.conn_id >>= fun () ->
          return false

let check_slack_team_connection slack_teamid =
  match get_connection slack_teamid with
  | None -> return false
  | Some x -> check_connection x

let get_slack_address esper_teamid =
  User_team.get esper_teamid >>= fun team ->
  User_preferences.get team >>= fun p ->
  match p.Api_t.pref_slack_address with
  | None -> Http_exn.bad_request `Slack_not_configured "Slack not configured"
  | Some x -> return x

let check_esper_team_connection teamid =
  get_slack_address teamid >>= fun x ->
  check_slack_team_connection x.Api_t.slack_teamid

(*
   Retry with exponential backoff until the specified operation returns
   true or fails with an exception.
*)
let retry_until_success ?(init_sleep = 1.) ?(max_sleep = 300.) f =
  if not (init_sleep > 0. && max_sleep >= init_sleep) then
    invalid_arg "Slack_ws_conn.retry";
  let rec loop sleep =
    f () >>=! fun success ->
    if success then
      return ()
    else (
      logf `Info "Retrying WS connection to Slack WS in %.3g s" sleep;
      Lwt_unix.sleep sleep >>= fun () ->
      loop (min (1.5 *. sleep) max_sleep)
    )
  in
  loop init_sleep

let rec check_connection_until_failure slack_teamid =
  check_slack_team_connection slack_teamid >>=! function
  | true ->
      Lwt_unix.sleep 15. >>=! fun () ->
      check_connection_until_failure slack_teamid
  | false ->
      return ()

(*
   Create a websocket connection for this Slack team
   (if there isn't one already), check regularly that the connection
   still works, and create a new connection if the previous one
   is no longer usable, and so on.
*)
let rec keep_connected slack_teamid input_handler =
  let connect () =
    Apputil_error.catch_and_report "Slack WS keep_connected"
      (fun () ->
         obtain_connection slack_teamid input_handler >>= fun conn ->
         logf `Info
           "Websocket created for Slack team %s"
           (Slack_api_teamid.to_string slack_teamid);
         return true
      )
      (fun e ->
         logf `Error
           "Retriable exception while creating Slack websocket %s: %s"
           (Slack_api_teamid.to_string slack_teamid) (string_of_exn e);
         return false
      )
  in
  retry_until_success connect >>=! fun () ->
  (* connection is now established *)
  check_connection_until_failure slack_teamid >>=! fun () ->
  (* connection is now dead and removed from the global table *)
  keep_connected slack_teamid input_handler

(*
   Testing:

   - log into Esper as the desired user
   - produce Slack auth URL: Slack.app_auth_url ()
   - visit that URL and follow the oauth steps
   - grab the auth token from the table slack_app_auth
*)
let test () =
  keep_connected
    (Slack_api_teamid.of_string "T19BY0R8X")
    (fun () send s ->
       Printf.printf "Received %S\n%!" s;
       return ()
    ) >>= fun conn ->
  push conn.send "{\"id\":0,\"type\":\"ping\"}"

let init () =
  return ()
