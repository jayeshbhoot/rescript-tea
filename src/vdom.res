type eventCallback = Dom.event => unit

type systemMessage<'msg> =
  | Render
  | AddRenderMsg('msg)
  | RemoveRenderMsg('msg)

type applicationCallbacks<'msg> = {
  enqueue: 'msg => unit,
  on: systemMessage<'msg> => unit,
}

type eventHandler<'msg> =
  | EventHandlerCallback(string, Dom.event => option<'msg>)
  | EventHandlerMsg('msg)

type eventCache<'msg> = {
  handler: eventCallback,
  cb: ref<Dom.event => option<'msg>>,
}

type property<'msg> =
  | NoProp
  | RawProp(string, string)
  | Attribute(string, string, string)
  | Data(string, string)
  | Event(string, eventHandler<'msg>, ref<option<eventCache<'msg>>>)
  | Style(list<(string, string)>)

type properties<'msg> = list<property<'msg>>

type rec t<'msg> =
  | CommentNode(string)
  | Text(string)
  | Node(string, string, string, string, properties<'msg>, list<t<'msg>>)

  | LazyGen(string, unit => t<'msg>, ref<t<'msg>>)
  | Tagger(ref<applicationCallbacks<'msg>> => ref<applicationCallbacks<'msg>>, t<'msg>)

let noNode: t<'msg> = (CommentNode(""): t<'msg>)

let comment = (s: string): t<'msg> => CommentNode(s)

let text = (s: string): t<'msg> => Text(s)

let fullnode = (
  namespace: string,
  tagName: string,
  key: string,
  unique: string,
  props: properties<'msg>,
  vdoms: list<t<'msg>>,
): t<'msg> => Node(namespace, tagName, key, unique, props, vdoms)

let node = (
  ~namespace: string="",
  tagName: string,
  ~key: string="",
  ~unique: string="",
  props: properties<'msg>,
  vdoms: list<t<'msg>>,
): t<'msg> => fullnode(namespace, tagName, key, unique, props, vdoms)

let lazyGen = (key: string, fn: unit => t<'msg>): t<'msg> => LazyGen(key, fn, ref(noNode))

let noProp: property<'msg> = (NoProp: property<'msg>)

let prop = (propName: string, value: string): property<'msg> => RawProp(propName, value)

let onCB = (~key: string, eventName: string, cb: Dom.event => option<'msg>): property<
  'msg,
> => Event(eventName, EventHandlerCallback(key, cb), ref(None))

let onMsg = (name: string, msg: 'msg): property<'msg> => Event(
  name,
  EventHandlerMsg(msg),
  ref(None),
)

let attribute = (namespace: string, key: string, value: string): property<'msg> => Attribute(
  namespace,
  key,
  value,
)
let booleanAttribute = (namespace, key, value) => {
  // The boolean characteristic of a boolean attribute
  // is denoted by the presence or absence of the attribute,
  // and not by true/false values.
  // e.g., https://developer.mozilla.org/en-US/docs/Web/HTML/Element/details#attr-open
  switch value {
  | true => attribute(namespace, key, "")
  | false => noProp
  }
}

let data = (key: string, value: string): property<'msg> => Data(key, value)

let style = (key: string, value: string): property<'msg> => Style(list{(key, value)})

let styles = (s): property<'msg> => Style(s)

let createElementNsOptional = (namespace, tagName) => {
  let document = Webapi.Dom.document
  switch namespace {
  | "" => Webapi.Dom.Document.createElement(document, tagName)
  | ns => Webapi.Dom.Document.createElementNS(document, ns, tagName)
  }
}

let nodeAt = (index: int, nodes: Dom.nodeList): Dom.node =>
  Webapi.Dom.NodeList.item(nodes, index) |> Belt.Option.getExn

@set_index external setItem: (Dom.element, 'key, 'value) => unit = ""
@get_index external _getItem: (Dom.element, 'key) => 'value = ""
let delItem = (elem: Dom.element, key: 'key) => setItem(elem, key, Js.Undefined.empty)

let rec renderToHtmlString: t<'msg> => string = (
  x =>
    switch x {
    | CommentNode(s) => "<!-- " ++ (s ++ " -->")
    | Text(s) => s
    | Node(namespace, tagName, _key, _unique, props, vdoms) =>
      let renderProp = x =>
        switch x {
        | NoProp => ""
        | RawProp(k, v) => String.concat("", list{" ", k, "=\"", v, "\""})
        | Attribute(_namespace, k, v) => String.concat("", list{" ", k, "=\"", v, "\""})
        | Data(k, v) => String.concat("", list{" data-", k, "=\"", v, "\""})
        | Event(_, _, _) => ""
        | Style(s) =>
          String.concat(
            "",
            list{
              " style=\"",
              String.concat(";", List.map(((k, v)) => String.concat("", list{k, ":", v, ";"}), s)),
              "\"",
            },
          )
        }
      String.concat(
        "",
        list{
          "<",
          namespace,
          if namespace == "" {
            ""
          } else {
            ":"
          },
          tagName,
          String.concat("", List.map(p => renderProp(p), props)),
          ">",
          String.concat("", List.map(v => renderToHtmlString(v), vdoms)),
          "</",
          tagName,
          ">",
        },
      )
    | LazyGen(_key, gen, _cache) =>
      let vdom = gen()
      renderToHtmlString(vdom)
    | Tagger(_tagger, vdom) => renderToHtmlString(vdom)
    }: t<'msg> => string
)

let emptyEventHandler: eventCallback = (_ev => (): eventCallback)

let emptyEventCB = (_ev): option<eventCallback> => None

let eventHandler = (
  callbacks: ref<applicationCallbacks<'msg>>,
  cb: ref<Dom.event => option<'msg>>,
): eventCallback =>
  ev =>
    switch cb.contents(ev) {
    | None => ()
    | Some(msg) => callbacks.contents.enqueue(msg)
    }

let eventHandlerGetCB: (eventHandler<'msg>, Dom.event) => option<'msg> = (
  x =>
    switch x {
    | EventHandlerCallback(_, cb) => cb
    | EventHandlerMsg(msg) => _ev => Some(msg)
    }: (eventHandler<'msg>, Dom.event) => option<'msg>
)

let compareEventHandlerTypes = (left: eventHandler<'msg>): (eventHandler<'msg> => bool) =>
  x =>
    switch x {
    | EventHandlerCallback(cb, _) =>
      switch left {
      | EventHandlerCallback(lcb, _) if cb == lcb => true
      | _ => false
      }
    | EventHandlerMsg(msg) =>
      switch left {
      | EventHandlerMsg(lmsg) if msg == lmsg => true
      | _ => false
      }
    }

let eventHandlerRegister = (
  callbacks: ref<applicationCallbacks<'msg>>,
  elem: Dom.eventTarget,
  name: string,
  handlerType: eventHandler<'msg>,
): option<eventCache<'msg>> => {
  let cb = ref(eventHandlerGetCB(handlerType))
  let handler = eventHandler(callbacks, cb)
  let () = Webapi.Dom.EventTarget.addEventListener(elem, name, handler)
  Some({handler: handler, cb: cb})
}

let eventHandlerUnregister = (elem: Dom.eventTarget, name: string): (
  option<eventCache<'msg>> => option<eventCache<'msg>>
) =>
  x =>
    switch x {
    | None => None
    | Some(cache) =>
      let () = Webapi.Dom.EventTarget.removeEventListener(elem, name, cache.handler)
      None
    }

let eventHandlerMutate = (
  callbacks: ref<applicationCallbacks<'msg>>,
  elem: Dom.eventTarget,
  oldName: string,
  newName: string,
  oldHandlerType: eventHandler<'msg>,
  newHandlerType: eventHandler<'msg>,
  oldCache: ref<option<eventCache<'msg>>>,
  newCache: ref<option<eventCache<'msg>>>,
): unit =>
  switch oldCache.contents {
  | None => newCache := eventHandlerRegister(callbacks, elem, newName, newHandlerType)
  | Some(oldcache) =>
    if oldName == newName {
      let () = newCache := oldCache.contents
      if compareEventHandlerTypes(oldHandlerType, newHandlerType) {
        ()
      } else {
        let cb = eventHandlerGetCB(newHandlerType)
        let () = oldcache.cb := cb
      }
    } else {
      let () = oldCache := eventHandlerUnregister(elem, oldName, oldCache.contents)
      let () = newCache := eventHandlerRegister(callbacks, elem, newName, newHandlerType)
    }
  }

let patchVNodesOnElemsPropertiesApplyAdd = (
  callbacks: ref<applicationCallbacks<'msg>>,
  elem: Dom.element,
  _idx: int,
  x,
) =>
  switch x {
  | NoProp => ()
  | RawProp(k, v) => setItem(elem, k, v)
  | Attribute(namespace, k, v) => Webapi.Dom.Element.setAttributeNS(elem, namespace, k, v)
  | Data(k, v) =>
    Js.log(("TODO:  Add Data Unhandled", k, v))
    failwith("TODO:  Add Data Unhandled")
  | Event(name, handlerType, cache) =>
    let eventTarget = Webapi.Dom.Element.asEventTarget(elem)
    cache := eventHandlerRegister(callbacks, eventTarget, name, handlerType)
  | Style(s) =>
    switch Webapi.Dom.HtmlElement.ofElement(elem) {
    | Some(elem) =>
      let elemStyle = Webapi.Dom.HtmlElement.style(elem)
      List.fold_left(
        ((), (k, v)) => Webapi.Dom.CssStyleDeclaration.setPropertyValue(elemStyle, k, v),
        (),
        s,
      )
    | None => failwith("Expected htmlelement in patchVNodesOnElems_PropertiesApplyAdd")
    }
  }

let patchVNodesOnElemsPropertiesApplyRemove = (
  _callbacks: ref<applicationCallbacks<'msg>>,
  elem: Dom.element,
  _idx: int,
  x,
) =>
  switch x {
  | NoProp => ()
  | RawProp(k, _v) => delItem(elem, k)
  | Attribute(namespace, k, _v) => Webapi.Dom.Element.removeAttributeNS(elem, namespace, k)
  | Data(k, v) =>
    Js.log(("TODO:  Remove Data Unhandled", k, v))
    failwith("TODO:  Remove Data Unhandled")
  | Event(name, _, cache) =>
    let eventTarget = Webapi.Dom.Element.asEventTarget(elem)
    cache := eventHandlerUnregister(eventTarget, name, cache.contents)
  | Style(s) =>
    switch Webapi.Dom.HtmlElement.ofElement(elem) {
    | Some(elem) =>
      let elemStyle = Webapi.Dom.HtmlElement.style(elem)
      List.fold_left(
        ((), (k, _v)) => Webapi.Dom.CssStyleDeclaration.removeProperty(elemStyle, k) |> ignore,
        (),
        s,
      )
    | None => failwith("Expected htmlelement in patchVNodesOnElems_PropertiesApply_Remove")
    }
  }

let patchVNodesOnElemsPropertiesApplyRemoveAdd = (
  callbacks: ref<applicationCallbacks<'msg>>,
  elem: Dom.element,
  idx: int,
  oldProp: property<'msg>,
  newProp: property<'msg>,
): unit => {
  let () = patchVNodesOnElemsPropertiesApplyRemove(callbacks, elem, idx, oldProp)
  let () = patchVNodesOnElemsPropertiesApplyAdd(callbacks, elem, idx, newProp)
}

let patchVNodesOnElemsPropertiesApplyMutate = (
  _callbacks: ref<applicationCallbacks<'msg>>,
  elem: Dom.element,
  _idx: int,
  oldProp: property<'msg>,
  x,
) =>
  switch x {
  | NoProp => failwith("This should never be called as all entries through NoProp are gated.")
  | RawProp(k, v) => setItem(elem, k, v)
  | Attribute(namespace, k, v) => Webapi.Dom.Element.setAttributeNS(elem, namespace, k, v)
  | Data(k, v) =>
    Js.log(("TODO:  Mutate Data Unhandled", k, v))
    failwith("TODO:  Mutate Data Unhandled")
  | Event(_newName, _newHandlerType, _newCache) =>
    failwith("This will never be called because it is gated")
  | Style(s) =>
    switch Webapi.Dom.HtmlElement.ofElement(elem) {
    | None => failwith("Expected htmlelement in patchVNodesOnElemsPropertiesApplyMutate")
    | Some(elem) =>
      let elemStyle = Webapi.Dom.HtmlElement.style(elem)
      switch oldProp {
      | Style(oldS) => List.fold_left2(((), (ok, ov), (nk, nv)) =>
          if ok == nk {
            if ov == nv {
              ()
            } else {
              Webapi.Dom.CssStyleDeclaration.setPropertyValue(elemStyle, nk, nv)
            }
          } else {
            let _: string = Webapi.Dom.CssStyleDeclaration.removeProperty(elemStyle, ok)
            Webapi.Dom.CssStyleDeclaration.setPropertyValue(elemStyle, nk, nv)
          }
        , (), oldS, s)
      | _ =>
        failwith(
          "Passed a non-Style to a new Style as a Mutations while the old Style is not actually a style!",
        )
      }
    }
  }

let rec patchVNodesOnElemsPropertiesApply = (
  callbacks: ref<applicationCallbacks<'msg>>,
  elem: Dom.element,
  idx: int,
  oldProperties: list<property<'msg>>,
  newProperties: list<property<'msg>>,
): bool =>
  @ocaml.warning("-4")
  switch (oldProperties, newProperties) {
  | (list{}, list{}) => true
  | (list{}, list{_newProp, ..._newRest}) => false
  | (list{_oldProp, ..._oldRest}, list{}) => false
  | (list{NoProp, ...oldRest}, list{NoProp, ...newRest}) =>
    patchVNodesOnElemsPropertiesApply(callbacks, elem, idx + 1, oldRest, newRest)
  | (
      list{RawProp(oldK, oldV) as oldProp, ...oldRest},
      list{RawProp(newK, newV) as newProp, ...newRest},
    ) =>
    let () = if oldK == newK && oldV == newV {
      ()
    } else {
      patchVNodesOnElemsPropertiesApplyMutate(callbacks, elem, idx, oldProp, newProp)
    }
    patchVNodesOnElemsPropertiesApply(callbacks, elem, idx + 1, oldRest, newRest)
  | (
      list{Attribute(oldNS, oldK, oldV) as oldProp, ...oldRest},
      list{Attribute(newNS, newK, newV) as newProp, ...newRest},
    ) =>
    let () = if oldNS == newNS && (oldK == newK && oldV == newV) {
      ()
    } else {
      patchVNodesOnElemsPropertiesApplyMutate(callbacks, elem, idx, oldProp, newProp)
    }
    patchVNodesOnElemsPropertiesApply(callbacks, elem, idx + 1, oldRest, newRest)
  | (
      list{Data(oldK, oldV) as oldProp, ...oldRest},
      list{Data(newK, newV) as newProp, ...newRest},
    ) =>
    let () = if oldK == newK && oldV == newV {
      ()
    } else {
      patchVNodesOnElemsPropertiesApplyMutate(callbacks, elem, idx, oldProp, newProp)
    }
    patchVNodesOnElemsPropertiesApply(callbacks, elem, idx + 1, oldRest, newRest)
  | (
      list{Event(oldName, oldHandlerType, oldCache) as _oldProp, ...oldRest},
      list{Event(newName, newHandlerType, newCache) as _newProp, ...newRest},
    ) =>
    let eventTarget = Webapi.Dom.Element.asEventTarget(elem)
    let () = eventHandlerMutate(
      callbacks,
      eventTarget,
      oldName,
      newName,
      oldHandlerType,
      newHandlerType,
      oldCache,
      newCache,
    )
    patchVNodesOnElemsPropertiesApply(callbacks, elem, idx + 1, oldRest, newRest)
  | (list{Style(oldS) as oldProp, ...oldRest}, list{Style(newS) as newProp, ...newRest}) =>
    let () = if oldS == newS {
      ()
    } else {
      patchVNodesOnElemsPropertiesApplyMutate(callbacks, elem, idx, oldProp, newProp)
    }
    patchVNodesOnElemsPropertiesApply(callbacks, elem, idx + 1, oldRest, newRest)
  | (list{oldProp, ...oldRest}, list{newProp, ...newRest}) =>
    let () = patchVNodesOnElemsPropertiesApplyRemoveAdd(callbacks, elem, idx, oldProp, newProp)
    patchVNodesOnElemsPropertiesApply(callbacks, elem, idx + 1, oldRest, newRest)
  }

let patchVNodesOnElemsProperties = (
  callbacks: ref<applicationCallbacks<'msg>>,
  elem: Dom.element,
  oldProperties: list<property<'msg>>,
  newProperties: list<property<'msg>>,
): bool => patchVNodesOnElemsPropertiesApply(callbacks, elem, 0, oldProperties, newProperties)

let genEmptyProps = (length: int): list<property<'msg>> => {
  let rec aux = (lst, x) =>
    switch x {
    | 0 => lst
    | len => aux(list{noProp, ...lst}, len - 1)
    }
  aux(list{}, length)
}

let mapEmptyProps = (props: list<property<'msg>>): list<property<'msg>> =>
  List.map(_ => noProp, props)

let rec patchVNodesOnElemsReplaceNode = (
  callbacks: ref<applicationCallbacks<'msg>>,
  elem: Dom.node,
  elems: Dom.nodeList,
  idx: int,
): (t<'msg> => unit) =>
  x =>
    switch x {
    | Node(newNamespace, newTagName, _newKey, _newUnique, newProperties, newChildren) =>
      let oldChild = nodeAt(idx, elems)
      let newChild = createElementNsOptional(newNamespace, newTagName)
      let _: bool = patchVNodesOnElemsProperties(
        callbacks,
        newChild,
        mapEmptyProps(newProperties),
        newProperties,
      )
      let newChildNode = Webapi.Dom.Element.asNode(newChild)
      let childChildren = Webapi.Dom.Node.childNodes(newChildNode)
      let () = patchVNodesOnElems(callbacks, newChildNode, childChildren, 0, list{}, newChildren)
      let _attachedChild = Webapi.Dom.Node.insertBefore(elem, ~new=newChildNode, ~before=oldChild)
      let _removedChild = Webapi.Dom.Node.removeChild(elem, ~child=oldChild)
    | _ => failwith("Node replacement should never be passed anything but a node itself")
    }

and patchVNodesOnElemsCreateElement = (callbacks: ref<applicationCallbacks<'msg>>): (
  t<'msg> => Dom.node
) =>
  x =>
    switch x {
    | CommentNode(s) =>
      Webapi.Dom.Document.createComment(Webapi.Dom.document, s) |> Webapi.Dom.Comment.asNode
    | Text(text) =>
      Webapi.Dom.Document.createTextNode(Webapi.Dom.document, text) |> Webapi.Dom.Text.asNode

    | Node(newNamespace, newTagName, _newKey, _unique, newProperties, newChildren) =>
      let newChild = createElementNsOptional(newNamespace, newTagName)

      @ocaml.warning("-8")
      let true = patchVNodesOnElemsProperties(
        callbacks,
        newChild,
        mapEmptyProps(newProperties),
        newProperties,
      )
      let newChildNode = Webapi.Dom.Element.asNode(newChild)
      let childChildren = Webapi.Dom.Node.childNodes(newChildNode)
      let () = patchVNodesOnElems(callbacks, newChildNode, childChildren, 0, list{}, newChildren)
      newChildNode
    | LazyGen(_newKey, newGen, newCache) =>
      let vdom = newGen()
      let () = newCache := vdom
      patchVNodesOnElemsCreateElement(callbacks, vdom)
    | Tagger(tagger, vdom) => patchVNodesOnElemsCreateElement(tagger(callbacks), vdom)
    }

and patchVNodesOnElemsMutateNode = (
  callbacks: ref<applicationCallbacks<'msg>>,
  elem: Dom.node,
  elems: Dom.nodeList,
  idx: int,
  oldNode: t<'msg>,
  newNode: t<'msg>,
): unit =>
  switch (oldNode, newNode) {
  | (
      Node(_oldNamespace, oldTagName, _oldKey, oldUnique, oldProperties, oldChildren) as _oldNode,
      Node(_newNamespace, newTagName, _newKey, newUnique, newProperties, newChildren) as newNode,
    ) =>
    if oldUnique != newUnique || oldTagName != newTagName {
      patchVNodesOnElemsReplaceNode(callbacks, elem, elems, idx, newNode)
    } else {
      let child = nodeAt(idx, elems)
      switch Webapi.Dom.Element.ofNode(child) {
      | None => failwith("Expected element in patchVNodesOnElems_MutateNode")
      | Some(childElement) =>
        let childChildren = Webapi.Dom.Node.childNodes(child)
        let () = if (
          patchVNodesOnElemsProperties(callbacks, childElement, oldProperties, newProperties)
        ) {
          ()
        } else {
          let () = Js.log(
            "VDom:  Failed swapping properties because the property list length changed, use `noProp` to swap properties instead, not by altering the list structure.  This is a massive inefficiency until this issue is resolved.",
          )
          patchVNodesOnElemsReplaceNode(callbacks, elem, elems, idx, newNode)
        }
        patchVNodesOnElems(callbacks, child, childChildren, 0, oldChildren, newChildren)
      }
    }
  | _ => failwith("Non-node passed to patchVNodesOnElemsMutateNode")
  }

and patchVNodesOnElems = (
  callbacks: ref<applicationCallbacks<'msg>>,
  elem: Dom.node,
  elems: Dom.nodeList,
  idx: int,
  oldVNodes: list<t<'msg>>,
  newVNodes: list<t<'msg>>,
): unit =>
  @ocaml.warning("-4")
  switch (oldVNodes, newVNodes) {
  | (list{Tagger(_oldTagger, oldVdom), ...oldRest}, _) =>
    patchVNodesOnElems(callbacks, elem, elems, idx, list{oldVdom, ...oldRest}, newVNodes)
  | (list{oldNode, ...oldRest}, list{Tagger(newTagger, newVdom), ...newRest}) =>
    let () = patchVNodesOnElems(
      newTagger(callbacks),
      elem,
      elems,
      idx,
      list{oldNode},
      list{newVdom},
    )
    patchVNodesOnElems(callbacks, elem, elems, idx + 1, oldRest, newRest)
  | (list{}, list{}) => ()
  | (list{}, list{newNode, ...newRest}) =>
    let newChild = patchVNodesOnElemsCreateElement(callbacks, newNode)
    let _attachedChild = Webapi.Dom.Node.appendChild(elem, ~child=newChild)
    patchVNodesOnElems(callbacks, elem, elems, idx + 1, list{}, newRest)
  | (list{_oldVnode, ...oldRest}, list{}) =>
    let child = nodeAt(idx, elems)
    let _removedChild = Webapi.Dom.Node.removeChild(elem, ~child)
    patchVNodesOnElems(callbacks, elem, elems, idx, oldRest, list{})
  | (list{CommentNode(oldS), ...oldRest}, list{CommentNode(newS), ...newRest}) if oldS == newS =>
    patchVNodesOnElems(callbacks, elem, elems, idx + 1, oldRest, newRest)
  | (list{Text(oldText), ...oldRest}, list{Text(newText), ...newRest}) =>
    let () = if oldText == newText {
      ()
    } else {
      let child = nodeAt(idx, elems)
      Webapi.Dom.Node.setNodeValue(child, Js.Null.return(newText))
    }
    patchVNodesOnElems(callbacks, elem, elems, idx + 1, oldRest, newRest)
  | (
      list{LazyGen(oldKey, _oldGen, oldCache), ...oldRest},
      list{LazyGen(newKey, newGen, newCache), ...newRest},
    ) =>
    if oldKey == newKey {
      let () = newCache := oldCache.contents
      patchVNodesOnElems(callbacks, elem, elems, idx + 1, oldRest, newRest)
    } else {
      switch (oldRest, newRest) {
      | (
          list{LazyGen(olderKey, _olderGen, _olderCache), ...olderRest},
          list{LazyGen(newerKey, _newerGen, _newerCache), ...newerRest},
        ) if olderKey == newKey && oldKey == newerKey =>
        let firstChild = nodeAt(idx, elems)
        let secondChild = nodeAt(idx + 1, elems)
        let _removedChild = Webapi.Dom.Node.removeChild(elem, ~child=secondChild)
        let _attachedChild = Webapi.Dom.Node.insertBefore(
          elem,
          ~new=secondChild,
          ~before=firstChild,
        )
        patchVNodesOnElems(callbacks, elem, elems, idx + 2, olderRest, newerRest)
      | (list{LazyGen(olderKey, _olderGen, olderCache), ...olderRest}, _) if olderKey == newKey =>
        let oldChild = nodeAt(idx, elems)
        let _removedChild = Webapi.Dom.Node.removeChild(elem, ~child=oldChild)
        let oldVdom = olderCache.contents
        let () = newCache := oldVdom
        patchVNodesOnElems(callbacks, elem, elems, idx + 1, olderRest, newRest)
      | (_, list{LazyGen(newerKey, _newerGen, _newerCache), ..._newerRest}) if newerKey == oldKey =>
        let oldChild = nodeAt(idx, elems)
        let newVdom = newGen()
        let () = newCache := newVdom
        let newChild = patchVNodesOnElemsCreateElement(callbacks, newVdom)
        let _attachedChild = Webapi.Dom.Node.insertBefore(elem, ~new=newChild, ~before=oldChild)
        patchVNodesOnElems(callbacks, elem, elems, idx + 1, oldVNodes, newRest)
      | _ =>
        let oldVdom = oldCache.contents
        let newVdom = newGen()
        let () = newCache := newVdom
        patchVNodesOnElems(
          callbacks,
          elem,
          elems,
          idx,
          list{oldVdom, ...oldRest},
          list{newVdom, ...newRest},
        )
      }
    }
  | (
      list{
        Node(oldNamespace, oldTagName, oldKey, _oldUnique, _oldProperties, _oldChildren) as oldNode,
        ...oldRest,
      },
      list{
        Node(newNamespace, newTagName, newKey, _newUnique, _newProperties, _newChildren) as newNode,
        ...newRest,
      },
    ) =>
    if oldKey == newKey && oldKey != "" {
      patchVNodesOnElems(callbacks, elem, elems, idx + 1, oldRest, newRest)
    } else if oldKey == "" || newKey == "" {
      let () = patchVNodesOnElemsMutateNode(callbacks, elem, elems, idx, oldNode, newNode)
      patchVNodesOnElems(callbacks, elem, elems, idx + 1, oldRest, newRest)
    } else {
      switch (oldRest, newRest) {
      | (
          list{
            Node(
              olderNamespace,
              olderTagName,
              olderKey,
              _olderUnique,
              _olderProperties,
              _olderChildren,
            ),
            ...olderRest,
          },
          list{
            Node(
              newerNamespace,
              newerTagName,
              newerKey,
              _newerUnique,
              _newerProperties,
              _newerChildren,
            ),
            ...newerRest,
          },
        )
        if olderNamespace == newNamespace &&
          (olderTagName == newTagName &&
          (olderKey == newKey &&
            (oldNamespace == newerNamespace &&
            (oldTagName == newerTagName && oldKey == newerKey)))) =>
        let firstChild = nodeAt(idx, elems)
        let secondChild = nodeAt(idx + 1, elems)
        let _removedChild = Webapi.Dom.Node.removeChild(elem, ~child=secondChild)
        let _attachedChild = Webapi.Dom.Node.insertBefore(
          elem,
          ~new=secondChild,
          ~before=firstChild,
        )
        patchVNodesOnElems(callbacks, elem, elems, idx + 2, olderRest, newerRest)
      | (
          list{
            Node(
              olderNamespace,
              olderTagName,
              olderKey,
              _olderUnique,
              _olderProperties,
              _olderChildren,
            ),
            ...olderRest,
          },
          _,
        ) if olderNamespace == newNamespace && (olderTagName == newTagName && olderKey == newKey) =>
        let oldChild = nodeAt(idx, elems)
        let _removedChild = Webapi.Dom.Node.removeChild(elem, ~child=oldChild)
        patchVNodesOnElems(callbacks, elem, elems, idx + 1, olderRest, newRest)
      | (
          _,
          list{
            Node(
              newerNamespace,
              newerTagName,
              newerKey,
              _newerUnique,
              _newerProperties,
              _newerChildren,
            ),
            ..._newerRest,
          },
        ) if oldNamespace == newerNamespace && (oldTagName == newerTagName && oldKey == newerKey) =>
        let oldChild = nodeAt(idx, elems)
        let newChild = patchVNodesOnElemsCreateElement(callbacks, newNode)
        let _attachedChild = Webapi.Dom.Node.insertBefore(elem, ~new=newChild, ~before=oldChild)
        patchVNodesOnElems(callbacks, elem, elems, idx + 1, oldVNodes, newRest)
      | _ =>
        let () = patchVNodesOnElemsMutateNode(callbacks, elem, elems, idx, oldNode, newNode)
        patchVNodesOnElems(callbacks, elem, elems, idx + 1, oldRest, newRest)
      }
    }
  | (list{_oldVnode, ...oldRest}, list{newNode, ...newRest}) =>
    let oldChild = nodeAt(idx, elems)
    let newChild = patchVNodesOnElemsCreateElement(callbacks, newNode)
    let _attachedChild = Webapi.Dom.Node.insertBefore(elem, ~new=newChild, ~before=oldChild)
    let _removedChild = Webapi.Dom.Node.removeChild(elem, ~child=oldChild)
    patchVNodesOnElems(callbacks, elem, elems, idx + 1, oldRest, newRest)
  }

let patchVNodesIntoElement = (
  callbacks: ref<applicationCallbacks<'msg>>,
  elem: Dom.node,
  oldVNodes: list<t<'msg>>,
  newVNodes: list<t<'msg>>,
): list<t<'msg>> => {
  let elems = Webapi.Dom.Node.childNodes(elem)
  let () = patchVNodesOnElems(callbacks, elem, elems, 0, oldVNodes, newVNodes)
  newVNodes
}

let patchVNodeIntoElement = (
  callbacks: ref<applicationCallbacks<'msg>>,
  elem: Dom.node,
  oldVNode: t<'msg>,
  newVNode: t<'msg>,
): list<t<'msg>> => patchVNodesIntoElement(callbacks, elem, list{oldVNode}, list{newVNode})

let wrapCallbacksOn:
  type a b. (a => b, systemMessage<a>) => systemMessage<b> =
  (func, x) =>
    switch x {
    | Render => Render
    | AddRenderMsg(msg) => AddRenderMsg(func(msg))
    | RemoveRenderMsg(msg) => RemoveRenderMsg(func(msg))
    }

let wrapCallbacks:
  type a b. (a => b, ref<applicationCallbacks<b>>) => ref<applicationCallbacks<a>> =
  (func, callbacks) =>
    Obj.magic(
      ref,
      {
        enqueue: (msg: a) => {
          let new_msg = func(msg)
          callbacks.contents.enqueue(new_msg)
        },
        on: smsg => {
          let new_smsg = wrapCallbacksOn(func, smsg)
          callbacks.contents.on(new_smsg)
        },
      },
    )

let map: ('a => 'b, t<'a>) => t<'b> = (
  (func, vdom) => {
    let tagger = wrapCallbacks(func)
    Tagger(Obj.magic(tagger), Obj.magic(vdom))
  }: ('a => 'b, t<'a>) => t<'b>
)
