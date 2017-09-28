(** Read and write a persistent list of VBD UUIDs.
    These functions are thread-safe.

    The list is saved into a file with name {!Consts.vbd_list_file_name}
    in the directory specified by {!Consts.xapi_nbd_persistent_dir}.

    The {!add} and {!remove} functions, which modify this persistent list,
    first check if the {!Consts.xapi_nbd_persistent_dir} directory exists,
    and create it if it doesn't.
*)

(** [add vbd_uuid] adds [vbd_uuid] to the persistent list of VBD UUIDs, and
    writes back the changes to disk. It does not check for duplicated VBD
    UUIDs: if this UUID is already in the list, it will be added again. *)
val add: string -> unit Lwt.t

(** [remove vbd_uuid] removes [vbd_uuid] from the persistent list of VBD UUIDs,
    and writes back the changes to disk. If this [vbd_uuid] occurs in the list
    multiple times, all occurrences will be removed. *)
val remove: string -> unit Lwt.t

(** Returns all of the VBD UUIDs stored on disk. The UUIDs are not
    deduplicated, if the same UUID is added multiple times using {!add}, then it
    will be repeated here too. *)
val get_all: unit -> (string list) Lwt.t
