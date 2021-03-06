(*
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

(** Make sure callbacks are always unregistered. drive the point home by reporting possible NPE's *)

(** return the set of instance fields that are assigned to a null literal in [procdesc] *)
val get_fields_nullified : Cfg.Procdesc.t -> Ident.FieldSet.t

val callback_checker_main : Callbacks.proc_callback_t
