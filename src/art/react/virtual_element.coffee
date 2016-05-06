Foundation = require 'art-foundation'
VirtualNode = require './virtual_node'
{
  log, compactFlatten, globalCount, time, stackTime, BaseObject, shallowClone
  inspect, keepIfRubyTrue, stackTime, isPlainObject, compactFlatten
  isWebWorker
  objectDiff
  Browser
  merge
  Promise
} = Foundation
{propsEq} = VirtualNode

CanvasElement = null
Element = null
Rectangle = "Rectangle"
if ArtEngineCore = Neptune.Art.Engine.Core
  {Shapes:{Rectangle}} = Neptune.Art.Engine.Elements
  {CanvasElement, Element, ElementFactory} = ArtEngineCore

errorElementProps = key:"ART_REACT_ERROR_CREATING_CHILD_PLACEHOLDER", color:"orange"

class VirtualElementLocalBase extends VirtualNode

  _updateElementProps: (newProps) ->
    addedOrChanged  = (k, v) => @element.setProperty k, v
    removed         = (k, v) => @element.resetProperty k
    @_updateElementPropsHelper newProps, addedOrChanged, removed

  _setElementChildren: (childElements) -> @element.setChildren childElements

  _newElement: (elementClassName, props, childElements, bindToElementOrNewCanvasElementProps)->
    element = ElementFactory.newElement @elementClassName, props, childElements

    if bindToElementOrNewCanvasElementProps
      if bindToElementOrNewCanvasElementProps instanceof Element
        bindToElementOrNewCanvasElementProps.addChild element
      else
        props = merge bindToElementOrNewCanvasElementProps,
          webgl: Browser.Parse.query().webgl == "true"
          children: [element]
        new CanvasElement props

    element.creator = @
    element

  ###
  execute the function 'f' on the Art.Engine Element associated with this VirtualElement.
  IN: f = (Art.Engine.Core.Element) -> x
  OUT: Promise returning x
  ###
  withElement: (f) -> new Promise (resolve) -> resolve f @element

class VirtualElementRemoteBase extends VirtualNode

  constructor: ->
    super
    @_sendRemoteQueuePending = false

  _setElementChildren: (childElements) ->
    remote.updateElement @element, children: childElements
    @_sendRemoteQueue()

  _newElement: (elementClassName, props, childElements, newCanvasElementProps) ->
    remoteId = remote.newElement @elementClassName, merge(props, children: childElements), newCanvasElementProps
    @_sendRemoteQueue()
    remoteId

  _updateElementProps: (newProps) ->
    setProps = {}; resetProps = []
    addedOrChanged  = (k, v) => setProps[k] = v
    removed         = (k, v) => resetProps.push k
    if changed = @_updateElementPropsHelper newProps, addedOrChanged, removed
      remote.updateElement @element, setProps, resetProps
      @_sendRemoteQueue()

    changed

  _sendRemoteQueue: ->
    unless @_sendRemoteQueuePending
      @_sendRemoteQueuePending = true
      @onNextReady =>
        remote.sendRemoteQueue()
        @_sendRemoteQueuePending = false

  ###
  execute the function 'f' on the Art.Engine Element associated with this VirtualElement.
  NOTE: runs in the main thread. 'f' is serialized, so it loses all closure state.
  IN: f = (Art.Engine.Core.Element) -> x
  OUT: Promise returning x

  TODO: we could allow additional arguments to be passed which would in turn be
  passed to 'f' on when invoked on the main thread:

    withElement: (f, args...) -> remote.evalWithElement @element, f, args
  ###
  withElement: (f) -> remote.evalWithElement @element, f

module.exports = class VirtualElement extends (if isWebWorker then VirtualElementRemoteBase else VirtualElementLocalBase)
  @created = 0
  @instantiated = 0

  emptyProps = {}
  constructor: (elementClassName, props, children) ->
    # globalCount "ReactVirtualElement_Created"
    VirtualElement.created++
    @elementClassName = elementClassName
    super props || emptyProps
    @children = @_validateChildren compactFlatten children, keepIfRubyTrue

  #################
  # Inspect
  #################
  @getter
    inspectedName: ->
      "<React.VirtualElement:#{@uniqueId} elementClassName: #{@elementClassName}, props: #{inspect @props}>"

  toCoffeescript: (indent = "") ->
    compactFlatten([
      "#{indent}#{@elementClassName}"
      if Object.keys(@props).length == 0
        "{}"
      else
        "\n  #{indent}#{k}: #{inspect v}" for k, v of @props
      if @children?.length > 0
        subIndent = indent + "  "
        for child in @children
          "\n#{child.toCoffeescript subIndent}"
    ]).join ''

  #################
  # Update
  #################
  _findOldChildToUpdate: (child)->
    oldChildren = @children
    for oldChild, i in oldChildren when oldChild
      if oldChild._canUpdateFrom child
        oldChildren[i] = null
        return oldChild
    null

  _canUpdateFrom: (b)->
    @elementClassName == b.elementClassName &&
    @key == b.key

  ###
  _fastUpdateChildren
    if no Nodes were added, removed or changed "types"
      _updateFrom newChild for all oldChildren
      return true
    else
      # use _slowUpdateChildren instead
      return false
  ###
  _fastUpdateChildren: (newChildren) ->
    oldChildren = @children
    return false unless oldChildren.length == newChildren.length
    for oldChild, i in oldChildren
      return false unless oldChild._canUpdateFrom newChildren[i]

    for oldChild, i in oldChildren
      oldChild._updateFrom newChildren[i]
    true

  _slowUpdateChildren: (newChildren) ->
    oldChildren = @children
    childElements = for newChild, i in newChildren
      finalChild = if oldChild = @_findOldChildToUpdate newChild
        newChildren[i] = oldChild._updateFrom newChild
      else
        newChild._instantiate @_parentComponent
      finalChild.element

    for child in oldChildren when child
      child._unmount()

    @_setElementChildren childElements
    @children = newChildren

  ###
  returns true if children changed
    if true, element.setChildren was called
    if false, the children individually may change, but
      this element's children are the same set
  ###
  _updateChildren: (newChildren) ->
    if @_fastUpdateChildren newChildren
      false
    else
      @_slowUpdateChildren newChildren
      true

  _unmount: ->
    for child in @children
      child._unmount()

  # returns this
  _updateFrom: (newNode) ->
    super
    return unless @element

    propsChanged    = @_updateElementProps newNode.props
    childrenChanged = @_updateChildren newNode.children

    # globalCount "ReactVirtualElement_UpdateFromTemporaryVirtualElement_#{if propsChanged || childrenChanged then 'Changed' else 'NoChange'}"

    @

  #####################
  # Instantiate
  #####################
  ###
  create element or componentInstance
  fully generate Virtual-AIM subbranch
  fully create all AIM elements
  returns this
  ###
  _instantiate: (parentComponent, bindToElementOrNewCanvasElementProps) ->
    super
    VirtualElement.instantiated++
    # globalCount "ReactVirtualElement_Instantiated"

    childElements = for c, i in @children
      try
        c._instantiate parentComponent
        c.element
      catch e
        console.error e.stack
        console.error """
          Error instantiating child:
            childIndex #{i}
            error: #{e}
            child: #{c}
            elementClassName: #{@elementClassName}
            props: #{inspect @props}
          """
        @_newErrorElement()

    @element = @_newElement @elementClassName, @props, childElements, bindToElementOrNewCanvasElementProps

    @

  ##################
  # PRIVATE
  ##################
  _newErrorElement: -> @_newElement Rectangle, errorElementProps

  # returns true if props changed
  _updateElementPropsHelper: (newProps, addedOrChanged, removed) ->
    oldPropsLength = @getPropsLength()
    oldProps = @props

    noChangeCount = 0
    noChange = -> noChangeCount++

    # objectDiff: (o1, o2, added, removed, changed, nochange, eq = defaultEq, o2KeyCount) ->
    newPropsLength = @setPropsLength objectDiff newProps, oldProps, addedOrChanged, removed, addedOrChanged, noChange, propsEq

    if newPropsLength == noChangeCount && oldPropsLength == newPropsLength
      false
    else
      @props = newProps
      true

