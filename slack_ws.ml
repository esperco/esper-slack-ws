open Lwt

(*
   - open websocket
   - post to elb
   - save timestamp of latest event
   - update socket connection
*)

let connections = Hashtbl.create 10

let create_connection slack_teamid =
  Slack.get_auth slack_teamid >>= function
  | None ->
      logf `Error "Cannot connect to Slack for team %s"
        (Slack_api_teamid.to_string slack_teamid);
      return ()
  | Some auth ->
      ...

let init () =
  return ()
