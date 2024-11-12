let cmd = (promise, tagger) => {
  open Vdom
  Tea_cmd.call(callbacks => {
    let _ = promise |> Js.Promise.then_(res =>
      switch tagger(res) {
      | Some(msg) =>
        let () = callbacks.contents.enqueue(msg)
        Js.Promise.resolve()
      | None => Js.Promise.resolve()
      }
    )
  })
}

let result = (promise, msg) => {
  open Vdom
  Tea_cmd.call(callbacks => {
    let enq = result => callbacks.contents.enqueue(msg(result))

    let _ =
      promise
      |> Js.Promise.then_(res => {
        let resolve = enq(Ok(res))
        Js.Promise.resolve(resolve)
      })
      |> Js.Promise.catch(err => {
        // inspired by: https://forum.rescript-lang.org/t/match-map-js-promise-error-to-something-sensible/3651/5
        let errStr: string = err->%raw("(x => String(x))")
        let reject = enq(Error(errStr))
        Js.Promise.resolve(reject)
      })
  })
}
