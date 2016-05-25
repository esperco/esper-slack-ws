let main ~offset =
  Cmdline.parse_options ~offset [];
  if not (Conf.is_set ()) then
    Esper_config.load_based_on_hostname ();
  let http_server = Slack_ws_http_serv.create_server () in
  let _websocket_launcher = Slack_ws.init () in
  Lwt_main.run http_server
