/*
 *  Copyright (c) 2014-present, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the BSD-style license found in the
 *  LICENSE file in the root directory of this source tree. An additional grant
 *  of patent rights can be found in the PATENTS file in the same directory.
 *
 */

#import "CKComponentAction.h"

#import <unordered_map>
#import <vector>
#import <array>

#import "CKAssert.h"
#import "CKMutex.h"
#import "CKComponent.h"
#import "CKInternalHelpers.h"
#import "CKComponentScopeHandle.h"
#import "CKComponentViewInterface.h"

void CKTypedComponentActionTypeVectorBuild(std::vector<const char *> &typeVector, const CKTypedComponentActionTypelist<> &list) { }
void CKConfigureInvocationWithArguments(NSInvocation *invocation, NSInteger index) { }

id CKTypedComponentActionValue::initialTarget(CKComponent *sender) const {
  switch (_variant) {
    case CKTypedComponentActionVariantRawSelector:
      return sender;
    case CKTypedComponentActionVariantTargetSelector:
      return _target;
    case CKTypedComponentActionVariantComponentScope:
      return _scopeHandle.responder;
  }
}

#pragma mark - CKTypedComponentActionValue

CKTypedComponentActionValue::CKTypedComponentActionValue() : _variant(CKTypedComponentActionVariantRawSelector), _target(nil), _scopeHandle(nil), _selector(NULL) {}

CKTypedComponentActionValue::CKTypedComponentActionValue(const CKTypedComponentActionValue &value) : _variant(value._variant), _target(value._target), _scopeHandle(value._scopeHandle), _selector(value._selector) {};

CKTypedComponentActionValue::CKTypedComponentActionValue(CKTypedComponentActionVariant variant, __unsafe_unretained id target, __unsafe_unretained CKComponentScopeHandle *scopeHandle, SEL selector) : _variant(variant), _target(target), _scopeHandle(scopeHandle), _selector(selector) {};

bool CKTypedComponentActionValue::operator==(const CKTypedComponentActionValue& rhs) const
{
  return (_variant == rhs._variant
          && CKObjectIsEqual(_target, rhs._target)
          && CKObjectIsEqual(_scopeHandle, rhs._scopeHandle)
          && _selector == rhs._selector);
}

CKComponentActionSendBehavior CKTypedComponentActionValue::defaultBehavior() const
{
  return (_variant == CKTypedComponentActionVariantRawSelector
          ? CKComponentActionSendBehaviorStartAtSenderNextResponder
          : CKComponentActionSendBehaviorStartAtSender);
};

#pragma mark - CKTypedComponentActionBase

CKTypedComponentActionBase::CKTypedComponentActionBase(id target, SEL selector) : _internal({CKTypedComponentActionVariantTargetSelector, target, nil, selector}) {};

CKTypedComponentActionBase::CKTypedComponentActionBase(const CKComponentScope &scope, SEL selector) : _internal({CKTypedComponentActionVariantComponentScope, nil, scope.scopeHandle(), selector}) {};

CKTypedComponentActionBase::CKTypedComponentActionBase(SEL selector) : _internal(CKTypedComponentActionVariantRawSelector, nil, nil, selector) {};

CKTypedComponentActionBase::CKTypedComponentActionBase(int s) : _internal({}) {};

CKTypedComponentActionBase::CKTypedComponentActionBase(long s) : _internal({}) {};

CKTypedComponentActionBase::CKTypedComponentActionBase(std::nullptr_t n) : _internal({}) {};

CKTypedComponentActionBase::operator bool() const { return bool(_internal); };

bool CKTypedComponentActionBase::isEqual(const CKTypedComponentActionBase &rhs) const { return _internal == rhs._internal; };

SEL CKTypedComponentActionBase::selector() const { return _internal.selector(); };

#pragma mark - Sending

NSInvocation *CKComponentActionSendResponderInvocationPrepare(SEL selector, id target, CKComponent *sender)
{
  id responder = [target targetForAction:selector withSender:target];
  CKCAssertNotNil(responder, @"Unhandled component action %@ following responder chain %@",
                  NSStringFromSelector(selector), _CKComponentResponderChainDebugResponderChain(target));
  // This is not performance-sensitive, so we can just use an invocation here.
  NSMethodSignature *signature = [responder methodSignatureForSelector:selector];
  while (!signature) {
    // From https://www.mikeash.com/pyblog/friday-qa-2009-03-27-objective-c-message-forwarding.html
    // 1. Lazy method resolution
    if ( [[responder class] resolveInstanceMethod:selector]) {
      signature = [responder methodSignatureForSelector:selector];
      // The responder resolved its instance method, we now have a valid responder/signature
      break;
    }

    // 2. Fast-forwarding path
    id forwardingTarget = [responder forwardingTargetForSelector:selector];
    if (!forwardingTarget || forwardingTarget == responder) {
      // Bail, the object they're asking us to message will just crash if the method is invoked on them
      CKCFailAssert(@"Forwarding target failed for action:%@ %@", target, NSStringFromSelector(selector));
      return nil;
    }

    responder = forwardingTarget;
    signature = [responder methodSignatureForSelector:selector];
  }
  NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
  invocation.selector = selector;
  invocation.target = responder;
  if (signature.numberOfArguments >= 3) {
    [invocation setArgument:&sender atIndex:2];
  }
  return invocation;
}

#pragma mark - Legacy Send Functions

void CKComponentActionSend(const CKComponentAction &action, CKComponent *sender)
{
  action.send(sender);
}

void CKComponentActionSend(const CKComponentAction &action, CKComponent *sender, CKComponentActionSendBehavior behavior)
{
  action.send(sender, behavior);
}

void CKComponentActionSend(CKTypedComponentAction<id> action, CKComponent *sender, id context)
{
  action.send(sender, CKComponentActionSendBehaviorStartAtSenderNextResponder, context);
}

void CKComponentActionSend(CKTypedComponentAction<id> action, CKComponent *sender, id context, CKComponentActionSendBehavior behavior)
{
  action.send(sender, behavior, context);
}

#pragma mark - Control Actions

@interface CKComponentActionControlForwarder : NSObject
- (instancetype)initWithAction:(CKTypedComponentAction<UIEvent *>)action;
- (void)handleControlEventFromSender:(UIControl *)sender withEvent:(UIEvent *)event;
@end

struct CKComponentActionHasher
{
  std::size_t operator()(const CKTypedComponentAction<UIEvent *>& k) const
  {
    return std::hash<void *>()(k.selector());
  }
};

typedef std::unordered_map<CKTypedComponentAction<UIEvent *>, CKComponentActionControlForwarder *, CKComponentActionHasher> ForwarderMap;

CKComponentViewAttributeValue CKComponentActionAttribute(CKTypedComponentAction<UIEvent *> action,
                                                         UIControlEvents controlEvents)
{
  static ForwarderMap *map = new ForwarderMap(); // never destructed to avoid static destruction fiasco
  static CK::StaticMutex lock = CK_MUTEX_INITIALIZER;   // protects map

  if (!action) {
    return {
      {"CKComponentActionAttribute-no-op", ^(UIControl *control, id value) {}, ^(UIControl *control, id value) {}},
      // Use a bogus value for the attribute's "value". All the information is encoded in the attribute itself.
      @YES
    };
  }

  // We need a target for the control event. (We can't use the responder chain because we need to jump in and change the
  // sender from the UIControl to the CKComponent.)
  // Control event targets are __unsafe_unretained. We can't rely on the block to keep the target alive, since the block
  // is merely an "applicator"; if the attributes compare the same (say, two equivalent attributes used across two
  // versions of the same component) then the block may be deallocated on the first one without removing the attribute.
  // Thus we create a map from component action to forwarders and never release the forwarders.
  // If this turns out to have memory overhead, we could capture a "token" in the blocks and have those tokens as ref-
  // counts on the forwarder, and when the number of outstanding tokens goes to zero, release the forwarder.
  // However I expect the number of actions to be O(200) at most and so the memory overhead is not a concern.
  CKComponentActionControlForwarder *forwarder;
  {
    CK::StaticMutexLocker l(lock);
    auto it = map->find(action);
    if (it == map->end()) {
      forwarder = [[CKComponentActionControlForwarder alloc] initWithAction:action];
      map->insert({action, forwarder});
    } else {
      forwarder = it->second;
    }
  }

  std::string identifier = std::string("CKComponentActionAttribute-")
  + std::string(sel_getName(action.selector()))
  + "-" + std::to_string(controlEvents);
  return {
    {
      identifier,
      ^(UIControl *control, id value){
        [control addTarget:forwarder
                    action:@selector(handleControlEventFromSender:withEvent:)
          forControlEvents:controlEvents];
      },
      ^(UIControl *control, id value){
        [control removeTarget:forwarder
                       action:@selector(handleControlEventFromSender:withEvent:)
             forControlEvents:controlEvents];
      }
    },
    // Use a bogus value for the attribute's "value". All the information is encoded in the attribute itself.
    @YES
  };
}

@implementation CKComponentActionControlForwarder
{
  CKTypedComponentAction<UIEvent *> _action;
}

- (instancetype)initWithAction:(CKTypedComponentAction<UIEvent *>)action
{
  if (self = [super init]) {
    _action = action;
  }
  return self;
}

- (void)handleControlEventFromSender:(UIControl *)sender withEvent:(UIEvent *)event
{
  // If the action can be handled by the sender itself, send it there instead of looking up the chain.
  _action.send(sender.ck_component, CKComponentActionSendBehaviorStartAtSender, event);
}

#pragma mark - Debug Helpers

static void checkMethodSignatureAgainstTypeEncodings(SEL selector, NSMethodSignature *signature, const std::vector<const char *> &typeEncodings)
{
#if DEBUG
  CKCAssert(typeEncodings.size() + 3 >= signature.numberOfArguments, @"Expected action method %@ to take less than %lu arguments, but it suppoorts %lu", NSStringFromSelector(selector), typeEncodings.size(), (unsigned long)signature.numberOfArguments - 3);

  CKCAssert(signature.methodReturnLength == 0, @"Component action methods should not have any return value. Any objects returned from this method will be leaked.");

  for (int i = 0; i + 3 < signature.numberOfArguments; i++) {
    const char *methodEncoding = [signature getArgumentTypeAtIndex:i + 3];
    const char *typeEncoding = typeEncodings[i];

    CKCAssert(methodEncoding == NULL || typeEncoding == NULL || strcmp(methodEncoding, typeEncoding) == 0, @"Implementation of %@ does not match expected types.\nExpected type %s, got %s", NSStringFromSelector(selector), typeEncoding, methodEncoding);
  }
#endif
}

void _CKTypedComponentDebugCheckComponentScope(const CKComponentScope &scope, SEL selector, const std::vector<const char *> &typeEncodings)
{
#if DEBUG
  // In DEBUG mode, we want to do the minimum of type-checking for the action that's possible in Objective-C. We
  // can't do exact type checking, but we can ensure that you're passing the right type of primitives to the right
  // argument indices.
  const Class klass = scope.scopeHandle().componentClass;
  // We allow component actions to be implemented either in the component, or its controller.
  const Class controllerKlass = CKComponentControllerClassFromComponentClass(klass);
  CKCAssert([klass instancesRespondToSelector:selector] || [controllerKlass instancesRespondToSelector:selector], @"Target does not respond to selector for component action. -[%@ %@]", klass, NSStringFromSelector(selector));

  NSMethodSignature *signature = [klass instanceMethodSignatureForSelector:selector] ?: [controllerKlass instanceMethodSignatureForSelector:selector];

  checkMethodSignatureAgainstTypeEncodings(selector, signature, typeEncodings);
#endif
}

void _CKTypedComponentDebugCheckTargetSelector(id target, SEL selector, const std::vector<const char *> &typeEncodings)
{
#if DEBUG
  // In DEBUG mode, we want to do the minimum of type-checking for the action that's possible in Objective-C. We
  // can't do exact type checking, but we can ensure that you're passing the right type of primitives to the right
  // argument indices.
  CKCAssert([target respondsToSelector:selector], @"Target does not respond to selector for component action. -[%@ %@]", [target class], NSStringFromSelector(selector));

  NSMethodSignature *signature = [target methodSignatureForSelector:selector];

  checkMethodSignatureAgainstTypeEncodings(selector, signature, typeEncodings);
#endif
}


// This method returns a friendly-print of a responder chain. Used for debug purposes.
NSString *_CKComponentResponderChainDebugResponderChain(id responder) {
  return (responder
          ? [NSString stringWithFormat:@"%@ -> %@", responder, _CKComponentResponderChainDebugResponderChain([responder nextResponder])]
          : @"nil");
}

@end

#pragma mark - Template instantiations

template class CKTypedComponentAction<>;
template class CKTypedComponentAction<id>;
