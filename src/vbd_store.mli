(** Read and write a persistent list of VBD UUIDs.
    These functions are thread-safe. *)

val add: string -> unit Lwt.t

val remove: string -> unit Lwt.t

val get_all: unit -> (string list) Lwt.t
