(*
   Maintain websocket connections to Slack.
*)

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

(*
   This global table holds at most one connection per Slack team.
   When a connection goes down it may be replaced by a None value to
   indicate that it will soon be replaced.
*)
let connections : (Slack_api_teamid.t, connection option) Hashtbl.t =
  Hashtbl.create 10

let get_stats () =
  let total = Hashtbl.length connections in
  let connected = Hashtbl.fold (fun k v n ->
    if v = None then n
    else n + 1
  ) connections 0
  in
  assert (connected <= total);
  (connected, total)

let report_stats () =
  let connected, total = get_stats () in
  let r = float connected /. float total in
  logf `Info "Fraction of live Slack websockets: %i/%i (%.0f%%)"
    connected total (100. *. r);
  if total > 0 then
    Cloudwatch.send "slack-ws.websocket.connected" r
  else
    return ()

let is_json_pong s =
  try
    (Slack_ws_j.type_only_of_string s).Slack_ws_j.type_ = "pong"
  with _ ->
    false

(* Warning: Slack doesn't respond to standard ping frames *)
let ping (send: send) =
  logf `Debug "WS send ping";
  send (Frame.create ~opcode:(Frame.Opcode.Ping) ())

let pong (send: send) =
  logf `Debug "WS send pong";
  send (Frame.create ~opcode:Frame.Opcode.Pong ())

let push (send: send) content =
  logf `Debug "WS send content %S" content;
  send (Frame.create ~content:(Bytes.copy content) ())

let close (send: send) =
  logf `Debug "WS send close";
  send (Frame.close 1000 (* normal closure *))

let connection_existed id =
  Hashtbl.mem connections id

let reserve_connection id =
  assert (not (connection_existed id));
  Hashtbl.add connections id None

let unreserve_connection id =
  try
    match Hashtbl.find connections id with
    | Some _ ->
        logf `Error "Cannot unreserve connection %s"
          (Slack_api_teamid.to_string id)
    | None ->
        Hashtbl.remove connections id
  with Not_found ->
    ()

(*
   Replace connection entry by None, indicating that there used to be
   a connection.
*)
let remove_connection id =
  try
    match Hashtbl.find connections id with
    | None -> return ()
    | Some {send} ->
        Hashtbl.replace connections id None;
        catch
          (fun () -> close send)
          (fun e ->
             logf `Error
               "Can't close websocket connection: %s" (string_of_exn e);
             return ()
          )
  with Not_found ->
    return ()

let remove_connection_completely slack_teamid =
  let closing = remove_connection slack_teamid in
  Hashtbl.remove connections slack_teamid;
  async (fun () -> closing)

let replace_connection x =
  let closing = remove_connection x.conn_id in
  Hashtbl.replace connections x.conn_id (Some x);
  async (fun () -> closing)

let async_with_timeout timeout f =
  async (fun () ->
    Util_lwt.with_timeout timeout f >>= function
    | None ->
        logf `Error "Slack websocket input handler timeout (%g s)" timeout;
        Apputil_error.report_error "Slack websocket input handler timeout" ""
    | Some () ->
        return ()
  )

(*
   Input is processed concurrently, with a timeout of 10 seconds.
   (see call to input_handler below)
*)
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
      else (
        logf `Debug "Slack WS: handle input";
        (* Run this in the background with a timeout so as to not block
           other incoming messages *)
        async_with_timeout 10. (fun () ->
          input_handler send frame.Frame.content
        );
        return ()
      )

  | Opcode.Continuation
  | Opcode.Ctrl _
  | Opcode.Nonctrl _ ->
      logf `Debug "Slack WS received Continuation, Ctrl, or Nonctrl";
      send (Frame.close 1002 (* protocol error *))

let tls_native client =
  match client with
  | `TLS conf when (Conf.get()).Conf_t.use_tls_native -> `TLS_native conf
  | _ -> client

let create_websocket_connection ws_url input_handler waiting_for_pong =
  let orig_uri = Uri.of_string ws_url in
  let uri = Uri.with_scheme orig_uri (Some "https") in
  Resolver_lwt.resolve_uri ~uri Resolver_lwt_unix.system >>= fun endp ->
  let ctx = Conduit_lwt_unix.default_ctx in
  Conduit_lwt_unix.endp_to_client ~ctx endp >>= fun client ->
  let client = tls_native client in
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

(*
   Some errors should be considered permanent by Esper, indicating
   that the Slack setup of the Esper user isn't usable and should be
   cleared.

   Error codes are not documented, so the list of errors that are
   considered permanent will grow as we discover more of such errors.
*)
let is_permanent_failure e =
  match e with
  | Slack_util.Slack_error "account_inactive" -> true
  | Slack_util.Slack_error _ -> false
  | _ -> false

type connection_result =
  | Retry
  | Giveup
  | Connected of connection

let create_connection slack_teamid input_handler handle_permanent_failure =
  logf `Debug "Create websocket connection for Slack team %s"
    (Slack_api_teamid.to_string slack_teamid);
  catch
    (fun () ->
       Slack_user.get_bot_access_token slack_teamid >>= fun access_token ->
       Slack_api.rtm_start access_token >>= fun resp ->
       match Slack_util.extract_result resp with
       | None ->
           return Retry
       | Some x ->
           let ws_url = x.Slack_api_t.url in
           let waiting_for_pong = ref None in
           create_websocket_connection ws_url
             input_handler waiting_for_pong >>= fun send ->
           let conn = {
             conn_id = slack_teamid;
             send;
             waiting_for_pong;
           } in
           return (Connected conn)
    )
    (fun e ->
       if is_permanent_failure e then (
         handle_permanent_failure slack_teamid >>= fun () ->
         return Giveup
       )
       else
         Trax.raise __LOC__ e
    )

let get_connection slack_teamid =
   try Hashtbl.find connections slack_teamid
   with Not_found -> None

let obtain_connection
    slack_teamid
    create_input_handler
    handle_permanent_failure =
  let mutex_key = "slack-ws:" ^ Slack_api_teamid.to_string slack_teamid in
  Redis_mutex.with_mutex ~atime:30. ~ltime:60 mutex_key (fun () ->
    match get_connection slack_teamid with
    | Some x -> return (Connected x)
    | None ->
        let input_handler = create_input_handler () in
        create_connection
          slack_teamid
          input_handler
          handle_permanent_failure >>= fun result ->
        (match result with
         | Connected conn ->
             replace_connection conn
         | Retry ->
             ()
         | Giveup ->
             remove_connection_completely slack_teamid
        );
        return result
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
           async (fun () ->
             push conn.send "{\"id\":0,\"type\":\"ping\"}"
           );
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

let get_slack_address esper_uid =
  User_preferences.get esper_uid >>= fun p ->
  return p.Api_t.pref_slack_address

let clear_slack_address esper_uid =
  User_preferences.update esper_uid (fun p ->
    return { p with Api_t.pref_slack_address = None }
  ) >>= fun p ->
  return ()

let interruptible_sleep sleep =
  let waiter, awakener = Lwt.wait () in
  let interrupt () =
    try
      Lwt.wakeup awakener ()
    with
    | Invalid_argument "Lwt.wakeup_result" -> ()
    | e -> Trax.raise __LOC__ e
  in
  let sleeper =
    Lwt.pick [
      Lwt_unix.sleep sleep;
      waiter;
    ]
  in
  sleeper, interrupt

(*
   Table of functions that can be used to shorten the sleep between
   retries with exponential backoff, which will result in an immediate
   retry.
*)
let sleepers = Hashtbl.create 100

let replace_sleeper conn_id interrupt =
  Hashtbl.replace sleepers conn_id interrupt

let interrupt_sleeper conn_id =
  let interrupt =
    try Hashtbl.find sleepers conn_id
    with Not_found -> (fun () -> ())
  in
  interrupt ()

(*
   Retry with exponential backoff until the specified operation returns
   true or fails with an exception.
*)
let retry_until_success ?(init_sleep = 1.) ?(max_sleep = 300.) conn_id f =
  if not (init_sleep > 0. && max_sleep >= init_sleep) then
    invalid_arg "Slack_ws_conn.retry";
  let rec loop sleep =
    f () >>=! fun success ->
    if success then
      return ()
    else (
      logf `Info "Retrying WS connection to Slack WS in %.3g s" sleep;
      let sleeper, interrupt = interruptible_sleep sleep in
      replace_sleeper conn_id interrupt;
      sleeper >>=! fun () ->
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
let keep_connected slack_teamid create_input_handler handle_permanent_failure =
  if connection_existed slack_teamid then (
    (* assume that another keep_connected job already exists *)
    interrupt_sleeper slack_teamid;
    return ()
  )
  else
    let rec retry () =
      Apputil_error.catch_and_report "Slack WS keep_connected (outer catch)"
        (fun () ->
           let connect () =
             Apputil_error.catch_and_report "Slack WS keep_connected"
               (fun () ->
                  obtain_connection slack_teamid
                    create_input_handler
                    handle_permanent_failure
                  >>= function
                  | Retry ->
                      return false
                  | Giveup ->
                      return true
                  | Connected conn ->
                      logf `Info
                        "Websocket created for Slack team %s"
                        (Slack_api_teamid.to_string slack_teamid);
                      return true
               )
               (fun e ->
                  logf `Error
                    "Retriable exception while creating Slack websocket %s: %s"
                    (Slack_api_teamid.to_string slack_teamid)
                    (string_of_exn e);
                  return false
               )
           in
           retry_until_success slack_teamid connect >>=! fun () ->
           (* connection is now established *)
           check_connection_until_failure slack_teamid
           (* connection is now dead and replaced by None
              in the global table *)
        )
        (fun e ->
           (* unexpected exception occurred *)
           logf `Error "Uncaught exception in Slack_ws_conn.keep_connected: %s"
             (string_of_exn e);
           unreserve_connection slack_teamid;
           return ()
        )
      >>=! fun () ->
      retry ()
    in
    reserve_connection slack_teamid;
    retry ()

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
    )
    (fun slack_teamid ->
       Printf.printf "Permanent failure\n%!";
       return ()
    )
