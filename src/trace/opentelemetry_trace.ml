module Otel = Opentelemetry
module Otrace = Trace_core (* ocaml-trace *)
module TLS = Thread_local_storage

open struct
  let spf = Printf.sprintf
end

module Conv = struct
  let[@inline] trace_id_of_otel (id : Otel.Trace_id.t) : Otrace.trace_id =
    if id == Otel.Trace_id.dummy then
      Otrace.Collector.dummy_trace_id
    else
      Bytes.unsafe_to_string (Otel.Trace_id.to_bytes id)

  let[@inline] trace_id_to_otel (id : Otrace.trace_id) : Otel.Trace_id.t =
    if id == Otrace.Collector.dummy_trace_id then
      Otel.Trace_id.dummy
    else
      Otel.Trace_id.of_bytes @@ Bytes.unsafe_of_string id

  let[@inline] span_id_of_otel (id : Otel.Span_id.t) : Otrace.span =
    if id == Otel.Span_id.dummy then
      Otrace.Collector.dummy_span
    else
      Bytes.get_int64_le (Otel.Span_id.to_bytes id) 0

  let[@inline] span_id_to_otel (id : Otrace.span) : Otel.Span_id.t =
    if id == Otrace.Collector.dummy_span then
      Otel.Span_id.dummy
    else (
      let b = Bytes.create 8 in
      Bytes.set_int64_le b 0 id;
      Otel.Span_id.of_bytes b
    )

  let[@inline] ctx_to_otel (self : Otrace.explicit_span_ctx) : Otel.Span_ctx.t =
    Otel.Span_ctx.make
      ~trace_id:(trace_id_to_otel self.trace_id)
      ~parent_id:(span_id_to_otel self.span)
      ()

  let[@inline] ctx_of_otel (ctx : Otel.Span_ctx.t) : Otrace.explicit_span_ctx =
    {
      trace_id = trace_id_of_otel (Otel.Span_ctx.trace_id ctx);
      span = span_id_of_otel (Otel.Span_ctx.parent_id ctx);
    }
end

open Conv

module Well_known = struct
  let spankind_key = "otrace.spankind"

  let internal = `String "INTERNAL"

  let server = `String "SERVER"

  let client = `String "CLIENT"

  let producer = `String "PRODUCER"

  let consumer = `String "CONSUMER"

  let spankind_of_string =
    let open Otel.Span in
    function
    | "INTERNAL" -> Span_kind_internal
    | "SERVER" -> Span_kind_server
    | "CLIENT" -> Span_kind_client
    | "PRODUCER" -> Span_kind_producer
    | "CONSUMER" -> Span_kind_consumer
    | _ -> Span_kind_unspecified

  let otel_attrs_of_otrace_data data =
    let kind : Otel.Span.kind ref = ref Otel.Span.Span_kind_unspecified in
    let data =
      List.filter_map
        (function
          | name, `String v when name = "otrace.spankind" ->
            kind := spankind_of_string v;
            None
          | x -> Some x)
        data
    in
    !kind, data

  (** Key to store an error [Otel.Span.status] with the message. Set
      ["otrace.error" = "mymsg"] in a span data to set the span's status to
      [{message="mymsg"; code=Error}]. *)
  let status_error_key = "otrace.error"
end

open Well_known

let on_internal_error =
  ref (fun msg -> Printf.eprintf "error in Opentelemetry_trace: %s\n%!" msg)

type Otrace.extension_event +=
  | Ev_link_span of Otrace.explicit_span * Otrace.explicit_span
  | Ev_set_span_kind of Otrace.explicit_span * Otel.Span_kind.t
  | Ev_record_exn of Otrace.explicit_span * exn * Printexc.raw_backtrace

module Internal = struct
  type span_begin = {
    start_time: int64;
    name: string;
    __FILE__: string;
    __LINE__: int;
    __FUNCTION__: string option;
    scope: Otel.Scope.t;
    parent: Otel.Span_ctx.t option;
  }

  module Active_span_tbl = Hashtbl.Make (struct
    include Int64

    let hash : t -> int = Hashtbl.hash
  end)

  (** key to access a OTEL scope from an explicit span *)
  let k_explicit_scope : Otel.Scope.t Otrace.Meta_map.key =
    Otrace.Meta_map.Key.create ()

  (** Per-thread set of active spans. *)
  module Active_spans = struct
    type t = { tbl: span_begin Active_span_tbl.t } [@@unboxed]

    let create () : t = { tbl = Active_span_tbl.create 32 }

    let k_tls : t TLS.t = TLS.create ()

    let[@inline] get () : t =
      try TLS.get_exn k_tls
      with TLS.Not_set ->
        let self = create () in
        TLS.set k_tls self;
        self
  end

  let otrace_of_otel (id : Otel.Span_id.t) : int64 =
    let bs = Otel.Span_id.to_bytes id in
    (* lucky that it coincides! *)
    assert (Bytes.length bs = 8);
    Bytes.get_int64_le bs 0

  let enter_span' ?(explicit_parent : Otrace.explicit_span_ctx option)
      ~__FUNCTION__ ~__FILE__ ~__LINE__ ~data name =
    let open Otel in
    let otel_id = Span_id.create () in
    let otrace_id = otrace_of_otel otel_id in

    let parent_scope = Scope.get_ambient_scope () in
    let trace_id =
      match parent_scope with
      | Some sc -> sc.trace_id
      | None -> Trace_id.create ()
    in
    let parent =
      match explicit_parent, parent_scope with
      | Some p, _ ->
        Some
          (Otel.Span_ctx.make ~trace_id ~parent_id:(span_id_to_otel p.span) ())
      | None, Some parent -> Some (Otel.Scope.to_span_ctx parent)
      | None, None -> None
    in

    let new_scope = Otel.Scope.make ~trace_id ~span_id:otel_id ~attrs:data () in

    let start_time = Timestamp_ns.now_unix_ns () in
    let sb =
      {
        start_time;
        name;
        __FILE__;
        __LINE__;
        __FUNCTION__;
        scope = new_scope;
        parent;
      }
    in

    let active_spans = Active_spans.get () in
    Active_span_tbl.add active_spans.tbl otrace_id sb;

    otrace_id, sb

  let exit_span_
      { start_time; name; __FILE__; __LINE__; __FUNCTION__; scope; parent } =
    let open Otel in
    let end_time = Timestamp_ns.now_unix_ns () in
    let kind, attrs = otel_attrs_of_otrace_data (Scope.attrs scope) in

    let status : Span_status.t =
      match List.assoc_opt Well_known.status_error_key attrs with
      | Some (`String message) -> { message; code = Status_code_error }
      | _ -> { message = ""; code = Status_code_ok }
    in

    let attrs =
      match __FUNCTION__ with
      | None ->
        [ "code.filepath", `String __FILE__; "code.lineno", `Int __LINE__ ]
        @ attrs
      | Some __FUNCTION__ ->
        let last_dot = String.rindex __FUNCTION__ '.' in
        let module_path = String.sub __FUNCTION__ 0 last_dot in
        let function_name =
          String.sub __FUNCTION__ (last_dot + 1)
            (String.length __FUNCTION__ - last_dot - 1)
        in
        [
          "code.filepath", `String __FILE__;
          "code.lineno", `Int __LINE__;
          "code.function", `String function_name;
          "code.namespace", `String module_path;
        ]
        @ attrs
    in

    let parent_id = Option.map Otel.Span_ctx.parent_id parent in
    Span.create ~kind ~trace_id:scope.trace_id ?parent:parent_id ~status
      ~id:scope.span_id ~start_time ~end_time ~attrs
      ~events:(Scope.events scope) name
    |> fst

  let exit_span' otrace_id otel_span_begin =
    let active_spans = Active_spans.get () in
    Active_span_tbl.remove active_spans.tbl otrace_id;
    exit_span_ otel_span_begin

  let exit_span_from_id otrace_id =
    let active_spans = Active_spans.get () in
    match Active_span_tbl.find_opt active_spans.tbl otrace_id with
    | None -> None
    | Some otel_span_begin ->
      Active_span_tbl.remove active_spans.tbl otrace_id;
      Some (exit_span_ otel_span_begin)

  let[@inline] get_scope (span : Otrace.explicit_span) : Otel.Scope.t option =
    Otrace.Meta_map.find k_explicit_scope span.meta

  module M = struct
    let with_span ~__FUNCTION__ ~__FILE__ ~__LINE__ ~data name cb =
      let otrace_id, sb =
        enter_span' ~__FUNCTION__ ~__FILE__ ~__LINE__ ~data name
      in

      Otel.Scope.with_ambient_scope sb.scope @@ fun () ->
      match cb otrace_id with
      | res ->
        let otel_span = exit_span' otrace_id sb in
        Otel.Trace.emit [ otel_span ];
        res
      | exception e ->
        let bt = Printexc.get_raw_backtrace () in

        Otel.Scope.record_exception sb.scope e bt;
        let otel_span = exit_span' otrace_id sb in
        Otel.Trace.emit [ otel_span ];

        Printexc.raise_with_backtrace e bt

    let enter_span ~__FUNCTION__ ~__FILE__ ~__LINE__ ~data name :
        Trace_core.span =
      let otrace_id, _sb =
        enter_span' ~__FUNCTION__ ~__FILE__ ~__LINE__ ~data name
      in
      (* NOTE: we cannot enter ambient scope in a disjoint way
         with the exit, because we only have [Ambient_context.with_binding],
         no [set_binding] *)
      otrace_id

    let exit_span otrace_id =
      match exit_span_from_id otrace_id with
      | None -> ()
      | Some otel_span -> Otel.Trace.emit [ otel_span ]

    let enter_manual_span ~(parent : Otrace.explicit_span_ctx option) ~flavor:_
        ~__FUNCTION__ ~__FILE__ ~__LINE__ ~data name : Otrace.explicit_span =
      let otrace_id, sb =
        match parent with
        | None -> enter_span' ~__FUNCTION__ ~__FILE__ ~__LINE__ ~data name
        | Some parent ->
          enter_span' ~explicit_parent:parent ~__FUNCTION__ ~__FILE__ ~__LINE__
            ~data name
      in

      let active_spans = Active_spans.get () in
      Active_span_tbl.add active_spans.tbl otrace_id sb;

      Otrace.
        {
          span = otrace_id;
          trace_id = trace_id_of_otel sb.scope.trace_id;
          meta = Meta_map.(empty |> add k_explicit_scope sb.scope);
        }

    let exit_manual_span Otrace.{ span = otrace_id; _ } =
      let active_spans = Active_spans.get () in
      match Active_span_tbl.find_opt active_spans.tbl otrace_id with
      | None -> !on_internal_error (spf "no active span with ID %Ld" otrace_id)
      | Some sb ->
        let otel_span = exit_span' otrace_id sb in
        Otel.Trace.emit [ otel_span ]

    let add_data_to_span otrace_id data =
      let active_spans = Active_spans.get () in
      match Active_span_tbl.find_opt active_spans.tbl otrace_id with
      | None -> !on_internal_error (spf "no active span with ID %Ld" otrace_id)
      | Some sb -> Otel.Scope.add_attrs sb.scope (fun () -> data)

    let add_data_to_manual_span (span : Otrace.explicit_span) data : unit =
      match get_scope span with
      | None ->
        !on_internal_error (spf "manual span does not a contain an OTEL scope")
      | Some scope -> Otel.Scope.add_attrs scope (fun () -> data)

    let message ?span ~data:_ msg : unit =
      (* gather information from context *)
      let old_scope = Otel.Scope.get_ambient_scope () in
      let trace_id = Option.map (fun sc -> sc.Otel.Scope.trace_id) old_scope in

      let span_id =
        match span with
        | Some id -> Some (span_id_to_otel id)
        | None -> Option.map (fun sc -> sc.Otel.Scope.span_id) old_scope
      in

      let log = Otel.Logs.make_str ?trace_id ?span_id msg in
      Otel.Logs.emit [ log ]

    let shutdown () = ()

    let name_process _name = ()

    let name_thread _name = ()

    let counter_int ~data name cur_val : unit =
      let _kind, attrs = otel_attrs_of_otrace_data data in
      let m = Otel.Metrics.(gauge ~name [ int ~attrs cur_val ]) in
      Otel.Metrics.emit [ m ]

    let counter_float ~data name cur_val : unit =
      let _kind, attrs = otel_attrs_of_otrace_data data in
      let m = Otel.Metrics.(gauge ~name [ float ~attrs cur_val ]) in
      Otel.Metrics.emit [ m ]

    let extension_event = function
      | Ev_link_span (sp1, sp2) ->
        (match get_scope sp1, get_scope sp2 with
        | Some sc1, Some sc2 ->
          Otel.Scope.add_links sc1 (fun () -> [ Otel.Scope.to_span_link sc2 ])
        | _ -> !on_internal_error "could not find scope for OTEL span")
      | Ev_set_span_kind (sp, k) ->
        (match get_scope sp with
        | None -> !on_internal_error "could not find scope for OTEL span"
        | Some sc -> Otel.Scope.set_kind sc k)
      | Ev_record_exn (sp, exn, bt) ->
        (match get_scope sp with
        | None -> !on_internal_error "could not find scope for OTEL span"
        | Some sc -> Otel.Scope.record_exception sc exn bt)
      | _ -> ()
  end
end

let link_spans (sp1 : Otrace.explicit_span) (sp2 : Otrace.explicit_span) : unit
    =
  if Otrace.enabled () then Otrace.extension_event @@ Ev_link_span (sp1, sp2)

let set_span_kind sp k : unit =
  if Otrace.enabled () then Otrace.extension_event @@ Ev_set_span_kind (sp, k)

let record_exception sp exn bt : unit =
  if Otrace.enabled () then Otrace.extension_event @@ Ev_record_exn (sp, exn, bt)

let collector () : Otrace.collector = (module Internal.M)

let setup () = Otrace.setup_collector @@ collector ()

let setup_with_otel_backend b : unit =
  Otel.Collector.set_backend b;
  setup ()
