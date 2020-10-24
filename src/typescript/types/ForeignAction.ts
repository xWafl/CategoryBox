import { Fn3, Fn2, Fn } from "@thi.ng/api"

// Those are here so we can do purescript interop properly
export type ForeignAction = { readonly foreignAction: unique symbol }

export interface ForeignActionConfig {
    createObject: Fn2<number, number, ForeignAction>;
    nothing: ForeignAction;
}