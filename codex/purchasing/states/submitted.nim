import pkg/metrics
import pkg/chronicles
import ../statemachine
import ./errorhandling
import ./started
import ./cancelled

logScope:
  topics = "marketplace purchases submitted"

declareCounter(codex_purchases_submitted, "codex purchases submitted")

type PurchaseSubmitted* = ref object of ErrorHandlingState

method `$`*(state: PurchaseSubmitted): string =
  "submitted"

method run*(state: PurchaseSubmitted, machine: Machine): Future[?State] {.async.} =
  codex_purchases_submitted.inc()
  let purchase = Purchase(machine)
  let request = !purchase.request
  let market = purchase.market
  let clock = purchase.clock

  info "Request submitted, waiting for slots to be filled", requestId = purchase.requestId

  proc wait {.async.} =
    let done = newFuture[void]()
    proc callback(_: RequestId) =
      done.complete()
    let subscription = await market.subscribeFulfillment(request.id, callback)
    await done
    await subscription.unsubscribe()

  proc withTimeout(future: Future[void]) {.async.} =
    let expiry = request.expiry.truncate(int64) + 1
    await future.withTimeout(clock, expiry)

  try:
    await wait().withTimeout()
  except Timeout:
    return some State(PurchaseCancelled())

  return some State(PurchaseStarted())
