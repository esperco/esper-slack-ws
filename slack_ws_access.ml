(*
   Keep track of the last Slack event to be processed successfully
   for a given channel.
*)

module Slack_latest = Mysql_access_k2v.Make (struct
  let tblname = "slack_latest"
  module Key1 = Key_team_user
  module Key2 = Slack_key_team_user
  module Value = struct
    type t = Slack_ws_t.latest
    let of_string x = Slack_ws_j.latest_of_string x
    let to_string x = Slack_ws_j.string_of_latest x
  end
  module Ord = struct
    type t = float
      (* timestamp parsed into a float without rounding to preserve
         microsecond precision *)
    let of_float x = x
    let to_float x = x
  end
  let create_ord k1 k2 v =
    Slack_api_ts.to_float v.Slack_ws_t.latest
  let update_ord = Some (fun k1 k2 v old_ord ->
    Slack_api_ts.to_float v.Slack_ws_t.latest
  )
end)
