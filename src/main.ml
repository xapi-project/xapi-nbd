(*
 * Copyright (C) 2015 Citrix Inc
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

let project_url = "http://github.com/djs55/xapi-nbd"

open Lwt
(* Xapi external interfaces: *)
module Xen_api = Xen_api_lwt_unix

(* Xapi internal interfaces: *)
module SM = Storage_interface.ClientM(struct
    type 'a t = 'a Lwt.t
    let fail, return, bind = Lwt.(fail, return, bind)

    let (>>*=) m f = m >>= function
      | `Ok x -> f x
      | `Error e ->
        let b = Buffer.create 16 in
        let fmt = Format.formatter_of_buffer b in
        Protocol_lwt.Client.pp_error fmt e;
        Format.pp_print_flush fmt ();
        fail (Failure (Buffer.contents b))

    (* A global connection for the lifetime of this process *)
    let switch =
      Protocol_lwt.Client.connect ~switch:!Xcp_client.switch_path ()
      >>*= fun switch ->
      return switch

    let rpc call =
      switch >>= fun switch ->
      Protocol_lwt.Client.rpc ~t:switch ~queue:!Storage_interface.queue_name ~body:(Jsonrpc.string_of_call call) ()
      >>*= fun result ->
      return (Jsonrpc.response_of_string result)
  end)

let uri = ref "http://127.0.0.1/"

let capture_exception f x =
  Lwt.catch
    (fun () -> f x >>= fun r -> return (`Ok r))
    (fun e -> return (`Error e))

let release_exception = function
  | `Ok x -> return x
  | `Error e -> fail e

let with_block filename f =
  let open Lwt in
  Block.connect filename
  >>= function
  | `Error _ -> fail (Failure (Printf.sprintf "Unable to read %s" filename))
  | `Ok x ->
    capture_exception f x
    >>= fun r ->
    Block.disconnect x
    >>= fun () ->
    release_exception r

let with_attached_vdi sr vdi read_write f =
  let pid = Unix.getpid () in
  let dbg = Printf.sprintf "xapi-nbd:with_attached_vdi/%d" pid in
  SM.DP.create ~dbg ~id:(Printf.sprintf "xapi-nbd/%s/%d" vdi pid)
  >>= fun dp ->
  SM.VDI.attach ~dbg ~dp ~sr ~vdi ~read_write
  >>= fun attach_info ->
  SM.VDI.activate ~dbg ~dp ~sr ~vdi
  >>= fun () ->
  capture_exception f attach_info.Storage_interface.params
  >>= fun r ->
  SM.DP.destroy ~dbg ~dp ~allow_leak:true
  >>= fun () ->
  release_exception r


let ignore_exn t () = Lwt.catch t (fun _ -> Lwt.return_unit)

let handle_connection fd tls_role =

  let with_session rpc uri f =
    ( match Uri.user uri, Uri.password uri, Uri.get_query_param uri "session_id" with
      | _, _, Some x ->
        (* Validate the session *)
        Xen_api.Session.get_uuid ~rpc ~session_id:x ~self:x
        >>= fun _ ->
        return (x, false)
      | Some uname, Some pwd, _ ->
        Xen_api.Session.login_with_password ~rpc ~uname ~pwd ~version:"1.0" ~originator:"xapi-nbd"
        >>= fun session_id ->
        return (session_id, true)
      | _, _, _ ->
        fail (Failure "No suitable authentication provided")
    ) >>= fun (session_id, need_to_logout) ->
    Lwt.finalize
      (fun () -> f uri rpc session_id)
      (fun () ->
         if need_to_logout
         then Xen_api.Session.logout ~rpc ~session_id
         else return ())
  in


  let serve t uri rpc session_id =
    let path = Uri.path uri in (* note preceeding / *)
    let vdi_uuid = if path <> "" then String.sub path 1 (String.length path - 1) else path in
    Xen_api.VDI.get_by_uuid ~rpc ~session_id ~uuid:vdi_uuid
    >>= fun vdi_ref ->
    Xen_api.VDI.get_record ~rpc ~session_id ~self:vdi_ref
    >>= fun vdi_rec ->
    Xen_api.SR.get_uuid ~rpc ~session_id ~self:vdi_rec.API.vDI_SR
    >>= fun sr_uuid ->
    with_attached_vdi sr_uuid vdi_rec.API.vDI_location (not vdi_rec.API.vDI_read_only)
      (fun filename ->
         with_block filename (Nbd_lwt_unix.Server.serve t (module Block))
      )
  in

  Nbd_lwt_unix.with_channel fd tls_role
    (fun channel ->
       Nbd_lwt_unix.Server.connect channel ()
       >>= fun (export_name, t) ->
       Lwt.finalize
         (fun () ->
            let rpc = Xen_api.make !uri in
            let uri = Uri.of_string export_name in
            with_session rpc uri (serve t)
         )
         (fun () -> Nbd_lwt_unix.Server.close t)
    )

(* TODO use the version from nbd repository *)
let init_tls_get_server_ctx ~certfile ~ciphersuites no_tls =
  if no_tls then None
  else (
    let certfile = require_str "certfile" certfile in
    let ciphersuites = require_str "ciphersuites" ciphersuites in
    Some (Nbd_lwt_unix.TlsServer
      (Nbd_lwt_unix.init_tls_get_ctx ~certfile ~ciphersuites)
    )
  )

let main port certfile ciphersuites no_tls =
  let tls_role = init_tls_get_server_ctx ~certfile ~ciphersuites no_tls in
  let t =
    let sock = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Lwt.finalize
      (fun () ->
         Lwt_unix.setsockopt sock Lwt_unix.SO_REUSEADDR true;
         let sockaddr = Lwt_unix.ADDR_INET(Unix.inet_addr_any, port) in
         Lwt_unix.bind sock sockaddr;
         Lwt_unix.listen sock 5;
         let rec loop () =
           Lwt_unix.accept sock
           >>= fun (fd, _) ->
           (* Background thread per connection *)
           let _ =
             Lwt.catch
               (fun () ->
                  Lwt.finalize
                    (fun () -> handle_connection fd tls_role)
                    (* ignore the exception resulting from double-closing the socket *)
                    (ignore_exn (fun () -> Lwt_unix.close fd))
               )
               (fun e -> Lwt_io.eprintf "Caught %s\n%!" (Printexc.to_string e))
           in
           loop ()
         in
         loop ()
      )
      (ignore_exn (fun () -> Lwt_unix.close sock))
  in
  Lwt_main.run t;

  `Ok ()

open Cmdliner

(* Help sections common to all commands *)

let _common_options = "COMMON OPTIONS"
let help = [
  `S _common_options;
  `P "These options are common to all commands.";
  `S "MORE HELP";
  `P "Use `$(mname) $(i,COMMAND) --help' for help on a single command."; `Noblank;
  `S "BUGS"; `P (Printf.sprintf "Check bug reports at %s" project_url);
]

let certfile =
  let doc = "Path to file containing TLS certificate." in
  Arg.(value & opt string "" & info ["certfile"] ~doc)
let ciphersuites =
  let doc = "Set of ciphersuites for TLS (specified in the format accepted by OpenSSL, stunnel etc.)" in
  Arg.(value & opt string "!EXPORT:RSA+AES128-SHA256" & info ["ciphersuites"] ~doc)
let no_tls =
  let doc = "Use NOTLS mode (refusing TLS) instead of the default FORCEDTLS." in
  Arg.(value & flag & info ["no-tls"] ~doc)

let cmd =
  let doc = "Expose VDIs over authenticated NBD connections" in
  let man = [
    `S "DESCRIPTION";
    `P "Expose all accessible VDIs over NBD. Every VDI is addressible through a URI, where the URI will be authenticated by xapi.";
  ] @ help in
  (* TODO for port, certfile, ciphersuites and no_tls: use definitions from nbd repository. *)
  (* But consider making ciphersuites mandatory here in a local definition. *)
  let port =
    let doc = "Local port to listen for connections on" in
    Arg.(value & opt int 10809 & info [ "port" ] ~doc) in
  Term.(ret (pure main $ port $ certfile $ ciphersuites $ no_tls)),
  Term.info "xapi-nbd" ~version:"1.0.0" ~doc ~man ~sdocs:_common_options

let _ =
  match Term.eval cmd with
  | `Error _ -> exit 1
  | _ -> exit 0
