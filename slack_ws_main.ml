(*
   Launch an http server that receives notifications from other Esper
   components and client websockets listening to each Slack team.
*)

let run id =
  Lwt.async Slack_ws_http_serv.create_server;
  Lwt.async Slack_ws.connect_all;
  Lwt.async Slack_ws.stats_loop;
  Util_lwt_main.loop ()

let main ~offset =
  Cmdline.parse_options ~offset [];
  if not (Conf.is_set ()) then
    Esper_config.load_based_on_hostname ();
  if not (Esper_config.is_prod ()) then (
    Log.level := `Debug;
    Util_http_client.trace := true
  );
  Serv_init.init "slack-ws" [0] run
