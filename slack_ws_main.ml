(*
   Launch an http server that receives notifications from other Esper
   components and client websockets listening to each Slack team.
*)

let run instance_id =
  Lwt.async Slack_ws_http_serv.create_server;
  Lwt.async Slack_ws.connect_all;
  Lwt.async Slack_ws.stats_loop;
  Lwt.async (fun () -> Slack_ws.monitor_process_health instance_id);
  Util_lwt_main.loop ()

let main ~offset =
  Cmdline.parse_options ~offset [];
  if not (Conf.is_set ()) then
    Esper_config.set_config_file_based_on_hostname ();
  if not (Esper_config.is_prod ()) then (
    Log.level := `Debug;
    Util_http_client.trace := true
  );
  let instance_id = Serv_init.({
    cloudwatch_prefix = "slack-ws";
    local_id = 0;
  }) in
  Serv_init.init "slack-ws" [instance_id] run
