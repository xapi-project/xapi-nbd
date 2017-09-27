open Lwt.Infix

let m = Lwt_mutex.create ()

let create_dir_if_doesnt_exist () =
  Lwt.catch
    (fun () -> Lwt_unix.mkdir Consts.xapi_nbd_persistent_dir 0o755)
    (function
      | Unix.(Unix_error (EEXIST, "mkdir", dir)) when dir = Consts.xapi_nbd_persistent_dir -> Lwt.return_unit
      | e ->
        Lwt_log.error_f "Failed to create directory: %s" (Printexc.to_string e)
    )

let transform_vbd_list f =
  Lwt_mutex.with_lock m (fun () ->
      create_dir_if_doesnt_exist () >>= fun () ->
      (try
         Lwt_io.lines_of_file Consts.vbd_list_file |> Lwt_stream.to_list
       with _ -> Lwt.return [])
      >>= fun l ->
      let l = f l in
      Lwt_stream.of_list l |> Lwt_io.lines_to_file Consts.vbd_list_file
    )

let add vbd_uuid =
  transform_vbd_list (List.append [vbd_uuid])

let remove vbd_uuid =
  transform_vbd_list (List.filter ((<>) vbd_uuid))

let get_all () =
  Lwt_unix.file_exists Consts.vbd_list_file >>= fun exists ->
  if exists then
    Lwt_mutex.with_lock m (fun () ->
        Lwt_io.lines_of_file Consts.vbd_list_file |> Lwt_stream.to_list)
  else
    Lwt.return []
