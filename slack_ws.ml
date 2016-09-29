(*
   Handler for incoming events:
   - respond to json pings
   - forward other incoming events to our http server
*)

open Printf
open Lwt
open Log
open Slack_ws_t
open Slack_ws_conn

let ( >>=! ) = Lwt.bind

let forward_event slack_teamid event_json =
  logf `Info "Forwarding event for Slack team %s"
    (Slack_api_teamid.to_string slack_teamid);
  let url = App_path.Webhook.slack_notif_url slack_teamid in
  Util_http_client.post ~body:event_json (Uri.of_string url)
  >>= fun (status, headers, body) ->
  match status with
  | `OK -> return ()
  | _ ->
      let error_id =
        sprintf "Slack event forwarder %s"
          (Cohttp.Code.string_of_status status)
      in
      let error_msg = body in
      Apputil_error.report_error error_id error_msg

let input_handler slack_teamid send event_json =
  forward_event slack_teamid event_json

let connect_team esper_teamid =
  Slack_ws_conn.get_slack_address esper_teamid >>= function
  | None -> return ()
  | Some slack_addr ->
      let slack_teamid = slack_addr.Api_t.slack_teamid in
      let loop =
        (* Ensure this gets started right away, in order to reserve
           the entry in the Slack_ws_conn.connections table. *)
        Slack_ws_conn.keep_connected
          slack_teamid
          (fun () ->
             logf `Debug "Create input handler";
             fun send content -> input_handler slack_teamid send content)
      in
      async (fun () -> loop);
      return ()

let connect_all () =
  Pay_active.iter_active_teams (fun team ->
    Apputil_error.catch_report_ignore "Initiate Slack session" (fun () ->
      connect_team team.Api_t.teamid
    )
  )

let rec stats_loop () =
  Lwt_unix.sleep 60. >>=! fun () ->
  async Slack_ws_conn.report_stats;
  stats_loop ()

let monitor_process_health instance_id =
  Health.monitor instance_id.Serv_init.cloudwatch_prefix
