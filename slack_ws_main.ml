(*
   Launch an http server that receives notifications from other Esper
   components and client websockets listening to each Slack team.
*)
let main ~offset =
  Cmdline.parse_options ~offset [];
  if not (Conf.is_set ()) then
    Esper_config.load_based_on_hostname ();
  let http_server = Slack_ws_http_serv.create_server () in
  let websocket_launcher = Slack_ws.connect_all () in
  let websocket_stats = Slack_ws.stats_loop () in
  Lwt_main.run (
    Lwt.join [
      http_server;
      websocket_launcher;
      websocket_stats;
    ]
  )
