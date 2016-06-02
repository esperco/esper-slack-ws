
open Lwt
open Log

(*
   - open websocket
   - post to elb
   - save timestamp of latest event
   - update socket connection
*)

type connection = {
  conn_id: Slack_api_teamid.t;
  push: string -> unit Lwt.t;
  close: unit -> unit Lwt.t;
  mutable waiting_for_pong: (bool Lwt.t * unit Lwt.u) option ref;
}

let connections = Hashtbl.create 10

let remove_connection id =
  try
    let {close} = Hashtbl.find connections id in
    Hashtbl.remove connections id;
    catch close
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
  let open Websocket_lwt.Frame in
  match frame.opcode with
  | Opcode.Ping ->
      send (Websocket_lwt.Frame.create ~opcode:Opcode.Pong ()) >>= fun () ->
      return true

  | Opcode.Close ->
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
      (match !waiting_for_pong with
       | None -> ()
       | Some (_, awakener) ->
           waiting_for_pong := None;
           Lwt.wakeup awakener ()
      );
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

let create_websocket_connection ws_url input_handler waiting_for_pong =
  let open Websocket_lwt.Frame in
  let orig_uri = Uri.of_string ws_url in
  let uri = Uri.with_scheme orig_uri (Some "https") in
  Resolver_lwt.resolve_uri ~uri Resolver_lwt_unix.system >>= fun endp ->
  let ctx = Conduit_lwt_unix.default_ctx in
  Conduit_lwt_unix.endp_to_client ~ctx endp >>= fun client ->
  Websocket_lwt.with_connection ~ctx client uri >>= fun (recv, send) ->

  let rec loop () =
    recv () >>= fun frame ->
    react input_handler waiting_for_pong send frame >>= function
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
      Http_exn.bad_request
        `Slack_authentication_missing
        "Slack authentication missing"
  | Some auth ->
      Slack_api.rtm_start auth.Slack_api_t.access_token >>= fun x ->
      let ws_url = x.Slack_api_t.url in
      let waiting_for_pong = ref None in
      create_websocket_connection ws_url
        input_handler waiting_for_pong >>= fun (push, close) ->
      let conn = {
        conn_id = slack_teamid;
        push;
        close;
        waiting_for_pong;
      } in
      return conn

let get_connection slack_teamid =
   try Some (Hashtbl.find connections slack_teamid)
   with Not_found -> None

let obtain_connection slack_teamid input_handler =
  let mutex_key = "slack-ws:" ^ Slack_api_teamid.to_string slack_teamid in
  Redis_mutex.with_mutex ~atime:30. ~ltime:60 mutex_key (fun () ->
    match get_connection slack_teamid with
    | Some x -> return x
    | None ->
        create_connection slack_teamid input_handler >>= fun conn ->
        replace_connection conn;
        return conn
  )

(*
   Send a ping and wait for a pong response for up to 10 seconds.
*)
let check_connection x =
  match !(x.waiting_for_pong) with
  | Some (result, _) ->
      result
  | None ->
      Apputil_error.catch_and_report "Slack Wwebsocket ping"
        (fun () ->
           let waiter, awakener = Lwt.wait () in
           let success = waiter >>= fun () -> return true in
           let failure = Lwt_unix.sleep 10. >>= fun () -> return false in
           let result = Lwt.pick [success; failure] in
           x.waiting_for_pong := Some (result, awakener);
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
            (Slack_api_teamid.to_string x.conn_id);
          remove_connection x.conn_id >>= fun () ->
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
   Testing:

   - log into Esper as the desired user
   - produce Slack auth URL: Slack.app_auth_url ()
   - visit that URL and follow the oauth steps
   - grab the auth token from the table slack_app_auth
*)

let init () =
  return ()
