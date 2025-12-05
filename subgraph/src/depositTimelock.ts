import { store } from "@graphprotocol/graph-ts";
import {
  Canceled as CanceledEvent,
  Deposited as DepositedEvent,
  Withdrawn as WithdrawnEvent,
} from "../generated/DepositTimelock/DepositTimelock";
import { Deposit as DepositEntity } from "../generated/schema";
import { createERC20Token } from "./utils";

export function handleDeposited(event: DepositedEvent): void {
  createERC20Token(event.params.token);

  const depositEntity = new DepositEntity(event.params.depositor.concat(event.params.context));
  depositEntity.depositor = event.params.depositor;
  depositEntity.target = event.params.target;
  depositEntity.context = event.params.context;
  depositEntity.token = event.params.token;
  depositEntity.amount = event.params.amount;
  depositEntity.expiration = event.params.expiration;
  depositEntity.save();
}

export function handleCanceled(event: CanceledEvent): void {
  store.remove("Deposit", event.params.depositor.concat(event.params.context).toHexString());
}

export function handleWithdrawn(event: WithdrawnEvent): void {
  store.remove("Deposit", event.params.depositor.concat(event.params.context).toHexString());
}
