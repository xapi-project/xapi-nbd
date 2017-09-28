(** This module provides two independent mechanisms for cleaning up leaked
    VBDs. They both work on their own, but they can also be combined for extra
    safety. *)

val ignore_exn_log_error : string -> (unit -> unit Lwt.t) -> unit Lwt.t

module VBD : sig
  val with_vbd :
    vDI:string ->
    vM:string ->
    mode:[ `RO | `RW ] ->
    rpc:(Rpc.call -> Rpc.response Lwt.t) ->
    session_id:string -> (string -> unit Lwt.t) -> unit Lwt.t
end

module Block : sig
  val with_block : string -> (Block.t -> 'a Lwt.t) -> 'a Lwt.t
end

module Runtime : sig
  val register_signal_handler : unit -> unit
end

module Persistent : sig
  val cleanup : unit -> unit Lwt.t
end
