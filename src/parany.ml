
module Dom = Domainslib
module Chan = Dom.Chan
module Ht = Hashtbl

exception End_of_input

let worker_loop jobs results work =
  let rec loop () =
    match Chan.recv jobs with
    | [||] ->
      (* signal muxer thread *)
      Chan.send results [||]
    | arr ->
      let res = Array.map work arr in
      Chan.send results res;
      loop () in
  loop ()

let demuxer_loop nprocs jobs csize demux =
  let rec loop () =
    let to_send = ref [] in
    try
      for _i = 1 to csize do
        to_send := (demux ()) :: !to_send
      done;
      let xs = Array.of_list (List.rev !to_send) in
      Chan.send jobs xs;
      loop ()
    with End_of_input ->
      begin
        if !to_send <> [] then
          begin
            let xs = Array.of_list (List.rev !to_send) in
            Chan.send jobs xs
          end;
        for _i = 1 to nprocs do
          (* signal each worker *)
          Chan.send jobs [||]
        done
      end in
  loop ()

let muxer_loop nprocs results mux =
  let finished = ref 0 in
  let rec loop () =
    match Chan.recv results with
    | [||] -> (* one worker finished *)
      begin
        incr finished;
        if !finished = nprocs then ()
        else loop ()
      end
    | xs ->
      begin
        Array.iter mux xs;
        loop ()
      end
  in
  loop ()

(* demux and index items *)
let idemux (demux: unit -> 'a) =
  let demux_count = ref 0 in
  function () ->
    let res = (!demux_count, demux ()) in
    incr demux_count;
    res

(* work, ignoring item index *)
let iwork (work: 'a -> 'b) ((i, x): int * 'a): int * 'b =
  (i, work x)

(* mux items in the right order *)
let imux (mux: 'b -> unit) =
  let mux_count = ref 0 in
  (* weak type variable avoidance *)
  let wait_list = Ht.create 11 in
  function (i, res) ->
    if !mux_count = i then
      begin
        (* unpile as much as possible *)
        mux res;
        incr mux_count;
        if Ht.length wait_list > 0 then
          try
            while true do
              let next = Ht.find wait_list !mux_count in
              Ht.remove wait_list !mux_count;
              mux next;
              incr mux_count
            done
          with Not_found -> () (* no more or index hole *)
      end
    else
      (* put somewhere into the pile *)
      Ht.add wait_list i res

let run ?(preserve = false) ?(csize = 1) (nprocs: int) ~demux ~work ~mux =
  if nprocs <= 1 then
    (* no overhead sequential version *)
    try
      while true do
        mux (work (demux ()))
      done
    with End_of_input -> ()
  else
    begin
      if preserve then
        (* nprocs workers + demuxer thread + muxer thread *)
        let jobs = Chan.make_bounded (50 * nprocs) in
        let results = Chan.make_bounded (50 * nprocs) in
        (* launch the workers *)
        let workers =
          Array.init nprocs (fun _rank ->
              Domain.spawn (fun _ ->
                  worker_loop jobs results (iwork work)
                )
            ) in
        (* launch the demuxer *)
        let demuxer = Domain.spawn (fun _ ->
            demuxer_loop nprocs jobs csize (idemux demux)
          ) in
        (* use the current thread to collect results (muxer) *)
        muxer_loop nprocs results (imux mux);
        (* wait all threads *)
        Domain.join demuxer;
        Array.iter Domain.join workers
      else
        (* WARNING: serious code duplication below... *)
        (* nprocs workers + demuxer thread + muxer thread *)
        let jobs = Chan.make_bounded (50 * nprocs) in
        let results = Chan.make_bounded (50 * nprocs) in
        (* launch the workers *)
        let workers =
          Array.init nprocs (fun _rank ->
              Domain.spawn (fun _ ->
                  worker_loop jobs results work
                )
            ) in
        (* launch the demuxer *)
        let demuxer = Domain.spawn (fun _ ->
            demuxer_loop nprocs jobs csize demux
          ) in
        (* use the current thread to collect results (muxer) *)
        muxer_loop nprocs results mux;
        (* wait all threads *)
        Domain.join demuxer;
        Array.iter Domain.join workers
    end
