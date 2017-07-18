open Core
open Async
open Kulfi_Routing
open Kulfi_Types
open Kulfi_Traffic
open Frenetic_OpenFlow
open Frenetic_OpenFlow0x01
open Message
open Frenetic_Network
open Net

module Controller = Frenetic_OpenFlow0x01_Plugin.LowLevel

(* Global Variables *)
let port_stats_delay = 1.0

let verbose s =
  if false then
    Core.eprintf "[kulfi]: %s\n%!" s
  else
    ()

let string_of_stats (sw:switchId) ((time:Int64.t), (ps:Frenetic_OpenFlow.portStats)) : string =
  Printf.sprintf
    "time=%Ld, switch=%Ld, port_no=%Ld, \
     rx_packets=%Ld, tx_packets=%Ld, \
     rx_bytes=%Ld, tx_bytes=%Ld, \
     rx_dropped=%Ld, tx_dropped=%Ld, \
     rx_errors=%Ld, tx_errors=%Ld, \
     rx_frame_err=%Ld, rx_over_err=%Ld, rx_crc_err=%Ld, \
     collisions=%Ld"
    time
    sw
    ps.port_no
    ps.port_rx_packets ps.port_tx_packets
    ps.port_rx_bytes ps.port_tx_bytes
    ps.port_rx_dropped ps.port_tx_dropped
    ps.port_rx_errors ps.port_tx_errors
    ps.port_rx_frame_err ps.port_rx_over_err ps.port_rx_crc_err
    ps.port_collisions

module Make(Solver:Kulfi_Routing.Algorithm) = struct

  type switch_state =
    { ports : portId list;
      flows : flowMod list }

  type state =
    { network : (switchId, switch_state) Hashtbl.t;
      stats : (switchId * portId, (int64 * Frenetic_OpenFlow.portStats) list) Hashtbl.t;
      topo : topology;
      mutable congestion : demand list;
      mutable churn : int list }

  let global_state : state =
    { network = Hashtbl.Poly.create ();
      stats = Hashtbl.Poly.create ();
      topo = Topology.empty ();
      congestion = [];
      churn = [] }

  (* Command-line Interface *)
  let rec cli () =
    let help () =
      Core.printf "Kulfi commands:\n\
                     \thelp : print this message\n\
                     \tswitches : print connected switches\n\
                     \tports [switch] : print ports for [switch]\n\
                     \tflows : print installed rules\n\
                     \tstats [switch] [port]: print port stats for [switch] and [port]\n\
                     \tdump [file]: dump all port stats to [file]\n\
                     %!";
      return () in
    let switches () =
      Core.printf
        "[%s]\n%!"
        (Kulfi_Types.intercalate
           (Printf.sprintf "%Ld")
           ", "
           (Hashtbl.Poly.keys global_state.network));
      return () in
    let ports sws =
      let sw = try Int64.of_string sws with _ -> -1L in
      begin match Hashtbl.Poly.find global_state.network sw with
            | None ->
               Core.printf "No ports for switch %s\n%!" sws
            | Some sw_state ->
               Core.printf
                 "[%s]\n%!"
                 (Kulfi_Types.intercalate
                    (Printf.sprintf "%d")
                    ", "
                    sw_state.ports)
      end;
      return () in
    let flows () =
      Core.printf
        "%s\n%!"
        (Hashtbl.Poly.fold
           global_state.network
           ~init:""
           ~f:(fun ~key:sw ~data:st acc ->
               Printf.sprintf
                 "%sswitch %Ld:\n%s"
                 (if acc = "" then "" else acc ^ "\n\n")
                 sw
                 (Kulfi_Types.intercalate Frenetic_OpenFlow0x01.FlowMod.to_string "\n" st.flows)));
      return () in

    let stats sws pts =
      let sw = try Int64.of_string sws with _ -> -1L in
      let pt = try Int.of_string pts with _ -> -1 in
      begin match Hashtbl.Poly.find global_state.stats (sw,pt) with
            | None
            | Some [] ->
               Core.printf "No stats for switch %s port %s\n" sws pts
            | Some ((time,ps)::_) ->
               Core.printf "%s\n" (string_of_stats sw (time,ps))
      end;
      return () in

    let dump fn =
      let buf = Buffer.create 101 in
      Hashtbl.iteri global_state.stats
        ~f:(fun ~key:(sw,pt) ~data:stats ->
          List.iter stats ~f:(fun (time,ps) ->
            Printf.bprintf buf "%s\n" (string_of_stats sw (time,ps))));
      Kulfi_Util.write_to_file fn (Buffer.contents buf);
      return () in

    let eof () =
      dump (Printf.sprintf "kulfi-controller-%f.txt" (Unix.time ())) >>=
      fun () -> Pervasives.exit 0 in
    let split s =
      List.filter (String.split s ' ') ((<>) "") in

    begin
      Core.printf "kulfi> %!";
      Reader.read_line (force Reader.stdin) >>=
        (function
          | `Eof -> eof ()
          | `Ok s -> match split s with
                     | ["switches"] -> switches ()
                     | ["ports"; sws] -> ports sws
                     | ["flows"] -> flows ()
                     | ["stats"; sws; pts] -> stats sws pts
                     | ["dump"; fn] -> dump fn
                     | ["exit"] -> eof ()
                     | _ -> help ()) >>= fun _ ->
      cli ()
    end

  (* Helper to create fresh xids *)
  let xid =
    let r = ref 0l in
    (fun () -> r := Int32.(!r + 1l); !r)

  (* Send messages to the controller, return xid *)
  let msgs,send_msg =
    let r,w = Pipe.create () in
    (r, fun (sw,m) ->
        let x = xid () in Pipe.write_without_pushback w (sw,x,m); x)

  (* Controller helper functions *)
  let rec port_stats_loop () : unit Deferred.t =
    Hashtbl.Poly.iteri
      global_state.network
      ~f:(fun ~key:sw ~data:sw_state ->
          List.iter
            sw_state.ports
            ~f:(fun p ->
                let m = Message.StatsRequestMsg (PortRequest (Some (PhysicalPort p))) in
                let _ = send_msg (sw, m) in
                ()));
    after (Time.Span.of_sec port_stats_delay) >>= fun () ->
    port_stats_loop ()

  let send (sw, x, msg) =
    let open Frenetic_OpenFlow0x01_Plugin in 
    Controller.send sw x msg >>= function
    | RpcEof -> return ()
    | RpcOk -> return ()

  let safe_add hash k v f =
    match Hashtbl.Poly.find hash k with
    | None -> Hashtbl.Poly.add_exn hash k v
    | Some v' -> Hashtbl.Poly.set hash k (f v v')

  let handler flow_hash evt =
    match evt with
    | SwitchUp (sw, ports) ->
       begin
         Core.printf "switch %Ld connected" sw;
         (* Save global state *)
         let sw_state =
           { ports = List.map ports ~f:(Int32.to_int_exn);
             flows =
               (match Hashtbl.Poly.find flow_hash sw with
                | None -> begin Core.printf "no flows!\n"; [] end
                | Some flows -> flows) } in
         safe_add global_state.network sw sw_state (fun x _ -> x);
         (* Propagate state to network *)
         send (sw, xid (), FlowModMsg delete_all_flows) >>= fun () ->
         send (sw, xid (), BarrierRequest) >>= fun () ->
         Deferred.all_unit
           (List.map sw_state.flows
                     (fun flow -> send (sw, xid (), FlowModMsg flow)))
       end
    | SwitchDown sw ->
       verbose (Printf.sprintf "switch %Ld disconnected" sw);
       Hashtbl.Poly.remove global_state.network sw;
       return ()
    | PortStats(sw, ps) ->
       verbose (Printf.sprintf "stats %s" (string_of_stats sw (0L,ps)));
       let time = Kulfi_Time.time () in
       safe_add global_state.stats (sw, Int64.to_int_exn ps.port_no) [(time, ps)] (@);
       return ()
    | _ ->
       return ()

  let initial_scheme init_str topo ic hm : scheme =
    match init_str with
    | None -> SrcDstMap.empty
    | Some "mcf" ->
       let d = next_demand ic hm in
       Kulfi_Routing.Mcf.solve topo d
    | Some "vlb" ->
       let d = next_demand ic hm in
       Kulfi_Routing.Vlb.solve topo d
    | Some "raeke" ->
       let d = next_demand ic hm in
       Kulfi_Routing.Raeke.solve topo d
    | Some "ecmp" ->
       let d = next_demand ic hm in
       Kulfi_Routing.Ecmp.solve topo d
    | Some _ -> failwith  "Unrecognized initialization scheme"

  (* Print flow mods to be installed *)
  let dump_flow_mods (sw_flow_map : (switchId, flowMod list) Hashtbl.t) =
    Hashtbl.iteri sw_flow_map
        ~f:(fun ~key:sw ~data:flows ->
          Kulfi_Types.intercalate Frenetic_OpenFlow0x01.FlowMod.to_string "\n" flows
          |> Core.printf "%d : %s\n" (Int64.to_int_exn sw))

  (* Start controller CLI loop and install flow rules *)
  let start_controller sw_flows_map () =
      Core.eprintf "[Kulfi: starting controller]\n%!";
      Controller.start 6633;
      Core.eprintf "[Kulfi: running...]\n%!";
      don't_wait_for (cli ());
      don't_wait_for (port_stats_loop ());
      don't_wait_for (Pipe.iter Controller.events (handler sw_flows_map));
      don't_wait_for (Pipe.iter msgs send);
      ()

  (* Source routing using a stack of tags (one per hop) for a path *)
  let start_src topo_fn predict_fn host_fn init_str () =
    (* Parse topology *)
    let topo = Frenetic_Network.Net.Parse.from_dotfile topo_fn in
    (* Create fabric *)
    let flow_hash,tag_hash = Kulfi_Fabric.create topo in
    (* Open predicted demands *)
    let (predict_host_map, predict_traffic_ic) = open_demands predict_fn host_fn topo in
    (* Helper to generate host configurations *)
    let scheme = initial_scheme init_str topo predict_traffic_ic predict_host_map in
    let _ = Solver.initialize scheme in
    let rec simulate i =
      try
        let predict = next_demand predict_traffic_ic predict_host_map in
        let scheme' = Solver.solve topo predict in
        print_configuration topo (source_routing_configuration_of_scheme topo scheme' tag_hash) i;
        simulate (i+1)
      with _ ->
        () in
    let open Deferred in
    (* Main code *)
    Core.eprintf "[Kulfi: generating configurations]\n%!";
    simulate 0;
    (*dump_flow_mods flow_hash;*)
    start_controller flow_hash ()


  (* Route using single tag per path *)
  let start_path topo_fn predict_fn host_fn init_str () =
    (* Parse topology *)
    let topo = Frenetic_Network.Net.Parse.from_dotfile topo_fn in
    (* Open predicted demands *)
    let (predict_host_map, predict_traffic_ic) = open_demands predict_fn host_fn topo in
    (* Helper to generate host configurations *)
    let scheme = initial_scheme init_str topo predict_traffic_ic predict_host_map in
    let _ = Solver.initialize scheme in
    let rec simulate i path_tag_map =
      try
        let predict = next_demand predict_traffic_ic predict_host_map in
        let scheme' = Solver.solve topo predict in
        Core.printf "%d\n%!" (SrcDstMap.length scheme');
        let path_tag_map = Kulfi_Paths.add_paths_from_scheme scheme' path_tag_map in
        print_configuration topo (path_routing_configuration_of_scheme topo scheme' path_tag_map) i;
        simulate (i+1) path_tag_map
      with err ->
        Core.printf "exit %d %s\n%!" i (Exn.to_string err);
        path_tag_map in
    let open Deferred in
    (* Main code *)
    Core.eprintf "[Kulfi: generating configurations]\n%!";
    (* Generate schemes for each iteration and create a tag for every path *)
    let path_tag_map = simulate 0 PathMap.empty in
    Core.eprintf "[Kulfi: %d]\n%!" (PathMap.length path_tag_map);
    (* translate path-tag map into flow mods for each switch *)
    let sw_flows_map = Kulfi_Paths.create_sw_flows_map topo path_tag_map in
    (*dump_flow_mods sw_flows_map;*)
    start_controller sw_flows_map ()


  (* select whether to do source routing or not and start controller *)
  let start topo_fn predict_fn host_fn init_str src_routing () =
    if src_routing then
      start_src topo_fn predict_fn host_fn init_str ()
    else
      start_path topo_fn predict_fn host_fn init_str ()

end
