
val with_session :
  ((Rpc.call -> Rpc.response Lwt.t) -> [`session] API.Ref.t -> 'a Lwt.t) ->
  'a Lwt.t
