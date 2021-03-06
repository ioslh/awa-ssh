(*
 * Copyright (c) 2016 Christiano F. Haesbaert <haesbaert@haesbaert.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

let () = Printexc.record_backtrace true

open Rresult.R
open Awa

let printf = Printf.printf

let read_cstruct fd =
  let len = Ssh.max_pkt_len in
  let buf = Bytes.create len in
  let n = Unix.read fd buf 0 len in
  if n = 0 then
    failwith "got EOF"
  else
    let cbuf = Cstruct.create n in
    Cstruct.blit_from_bytes buf 0 cbuf 0 n;
    cbuf

let write_cstruct fd buf =
  let len = Cstruct.len buf in
  let bytes = Bytes.create len in
  Cstruct.blit_to_bytes buf 0 bytes 0 len;
  let n = Unix.write fd bytes 0 len in
  assert (n > 0)

(* NEW SHIT *)
let rec output_msg_loop t fd msgs =
  let open Server in
  match msgs with
  | [] -> ok t
  | msg :: tl ->
    match action_of_msg t msg with
    | Send_data (t, data) ->
      Printf.printf ">>> %s\n%!" (Ssh.message_to_string msg);
      write_cstruct fd data;
      output_msg_loop t fd tl
    | Disconnect (t, data) ->
      Printf.printf ">>> %s\n%!" (Ssh.message_to_string msg);
      write_cstruct fd data;
      error "We sent a disconnect"
    | Ssh_error e -> error e

let rec input_msg_loop t fd =
  Server.pop_msg t >>= fun (t, msg) ->
  match msg with
  | None -> ok t
  | Some msg ->
    Printf.printf "<<< %s\n%!" (Ssh.message_to_string msg);
    Server.handle_msg t msg >>= fun (t, replies) ->
    match replies with
    | [] -> input_msg_loop t fd
    | replies ->
      (* Process our replies (actions) *)
      output_msg_loop t fd replies >>= fun t ->
      (* Loop for more input *)
      input_msg_loop t fd

let rec main_loop t fd =
  let buf = read_cstruct fd in
  let t = Server.input_buf t buf in
  input_msg_loop t fd >>= fun t ->
  main_loop t fd

let get_ok_s = function
  | Ok x -> x
  | Error s -> failwith s

let user_db =
  (* User foo auths by passoword *)
  let foo = Server.{ name = "foo"; password = Some "bar"; keys = [] } in
  (* User awa auths by pubkey *)
  let fd = Unix.(openfile "test/awa_test_rsa.pub" [O_RDONLY] 0) in
  let file_buf = Unix_cstruct.of_fd fd in
  let key = get_ok (Wire.pubkey_of_openssh file_buf) in
  Unix.close fd;
  let awa = Server.{ name = "awa"; password = None; keys = [ key ] } in
  [ foo; awa ]

let () =
  Nocrypto.Rng.reseed (Cstruct.of_string "180586");
  let server_port = 18022 in
  let listen_fd = Unix.(socket PF_INET SOCK_STREAM 0) in
  Unix.(setsockopt listen_fd SO_REUSEADDR true);
  Unix.(bind listen_fd (ADDR_INET (inet_addr_any, server_port)));
  Unix.listen listen_fd 1;
  let client_fd, _ = Unix.(accept listen_fd) in
  let rsa = Hostkey.Rsa_priv (Nocrypto.Rsa.generate 2048) in
  let t, greetings = Server.make rsa user_db in
  match output_msg_loop t client_fd greetings >>= fun t -> main_loop t client_fd with
  | Ok _ -> printf "ok"
  | Error e -> printf "error: %s" e
