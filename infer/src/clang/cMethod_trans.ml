(*
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

(** Methods for creating a procdesc from a method or function declaration *)
(**   and for resolving a method call and finding the right callee *)

open Utils
open CFrontend_utils

module L = Logging

exception Invalid_declaration

(** When the methoc call is MCStatic, means that it is a class method. *)
(** When it is MCVirtual, it means that it is an instance method and that *)
(** the method to be called will be determined at runtime. If it is MCNoVirtual *)
(** it means that it is an instance method but that the method to be called will *)
(** be determined at compile time *)
type method_call_type =
  | MCVirtual
  | MCNoVirtual
  | MCStatic

type function_method_decl_info =
  | Func_decl_info of Clang_ast_t.function_decl_info * Clang_ast_t.type_ptr * CFrontend_config.lang
  | Cpp_Meth_decl_info of Clang_ast_t.function_decl_info * string * Clang_ast_t.type_ptr
  | ObjC_Meth_decl_info of Clang_ast_t.obj_c_method_decl_info * string
  | Block_decl_info of Clang_ast_t.block_decl_info * Clang_ast_t.type_ptr * CContext.t

let is_instance_method function_method_decl_info =
  match function_method_decl_info with
  | Func_decl_info _  | Block_decl_info _ -> false
  | Cpp_Meth_decl_info _ -> true
  | ObjC_Meth_decl_info (method_decl_info, _) ->
      method_decl_info.Clang_ast_t.omdi_is_instance_method

let get_class_param function_method_decl_info =
  if (is_instance_method function_method_decl_info) then
    match function_method_decl_info with
    | Cpp_Meth_decl_info (_, class_name, _) ->
        let class_type = Ast_expressions.create_class_type class_name in
        [(CFrontend_config.this, class_type, None)]
    | ObjC_Meth_decl_info (_, class_name) ->
        let class_type = Ast_expressions.create_class_type class_name in
        [(CFrontend_config.self, class_type, None)]
    | _ -> []
  else []

let get_param_decls function_method_decl_info =
  match function_method_decl_info with
  | Func_decl_info (function_decl_info, _, _)
  | Cpp_Meth_decl_info (function_decl_info, _, _) -> function_decl_info.Clang_ast_t.fdi_parameters
  | ObjC_Meth_decl_info (method_decl_info, _) -> method_decl_info.Clang_ast_t.omdi_parameters
  | Block_decl_info (block_decl_info, _, _) -> block_decl_info.Clang_ast_t.bdi_parameters

let get_language function_method_decl_info =
  match function_method_decl_info with
  | Func_decl_info (_, _, language) -> language
  | Cpp_Meth_decl_info _ -> CFrontend_config.CPP
  | ObjC_Meth_decl_info _ -> CFrontend_config.OBJC
  | Block_decl_info _ -> CFrontend_config.OBJC

let get_parameters function_method_decl_info =
  let par_to_ms_par par =
    match par with
    | Clang_ast_t.ParmVarDecl (decl_info, name_info, type_ptr, var_decl_info) ->
        let name = name_info.Clang_ast_t.ni_name in
        (name, type_ptr, var_decl_info.Clang_ast_t.vdi_init_expr)
    | _ -> assert false in

  let pars = list_map par_to_ms_par (get_param_decls function_method_decl_info) in
  get_class_param function_method_decl_info @ pars

let get_return_type function_method_decl_info =
  match function_method_decl_info with
  | Func_decl_info (_, typ, _)
  | Cpp_Meth_decl_info (_, _, typ)
  | Block_decl_info (_, typ, _) -> CTypes.return_type_of_function_type typ
  | ObjC_Meth_decl_info (method_decl_info, _) -> method_decl_info.Clang_ast_t.omdi_result_type

let build_method_signature decl_info procname function_method_decl_info is_anonym_block is_generated =
  let source_range = decl_info.Clang_ast_t.di_source_range in
  let tp = get_return_type function_method_decl_info in
  let is_instance_method = is_instance_method function_method_decl_info in
  let parameters = get_parameters function_method_decl_info in
  let attributes = decl_info.Clang_ast_t.di_attributes in
  let lang = get_language function_method_decl_info in
  CMethod_signature.make_ms procname parameters tp attributes source_range is_instance_method
    is_generated lang

let get_assume_not_null_calls ms param_decls =
  let attributes = CMethod_signature.ms_get_attributes ms in
  let do_one_param decl = match decl with
    | Clang_ast_t.ParmVarDecl (decl_info, name, tp, var_decl_info)
      when CFrontend_utils.Ast_utils.is_type_nonnull tp attributes ->
        let assume_call = Ast_expressions.create_assume_not_null_call decl_info name tp in
        [(`ClangStmt assume_call)]
    | _ -> [] in
  list_flatten (list_map do_one_param param_decls)

let method_signature_of_decl class_name_opt meth_decl block_data_opt =
  let open Clang_ast_t in
  match meth_decl, block_data_opt, class_name_opt with
  | FunctionDecl (decl_info, name_info, tp, fdi), _, _ ->
      let name = name_info.ni_name in
      let language = !CFrontend_config.language in
      let func_decl = Func_decl_info (fdi, tp, language) in
      let function_info = Some (decl_info, fdi) in
      let procname = General_utils.mk_procname_from_function name function_info tp language in
      let ms = build_method_signature decl_info procname func_decl false false in
      let extra_instrs = get_assume_not_null_calls ms fdi.Clang_ast_t.fdi_parameters in
      ms, fdi.Clang_ast_t.fdi_body, extra_instrs
  | CXXMethodDecl (decl_info, name_info, tp, fdi, _), _, Some class_name ->
      let method_name = name_info.Clang_ast_t.ni_name in
      let procname = General_utils.mk_procname_from_cpp_method class_name method_name tp in
      let method_decl = Cpp_Meth_decl_info (fdi, class_name, tp)  in
      let ms = build_method_signature decl_info procname method_decl false false in
      let extra_instrs = get_assume_not_null_calls ms fdi.Clang_ast_t.fdi_parameters in
      ms, fdi.Clang_ast_t.fdi_body, extra_instrs
  | ObjCMethodDecl (decl_info, name_info, mdi), _, Some class_name ->
      let method_name = name_info.ni_name in
      let is_instance = mdi.omdi_is_instance_method in
      let method_kind = Procname.objc_method_kind_of_bool is_instance in
      let procname = General_utils.mk_procname_from_objc_method class_name method_name method_kind in
      let method_decl = ObjC_Meth_decl_info (mdi, class_name) in
      let is_generated = Ast_utils.is_generated name_info in
      let ms = build_method_signature decl_info procname method_decl false is_generated in
      let extra_instrs = get_assume_not_null_calls ms mdi.omdi_parameters in
      ms, mdi.omdi_body, extra_instrs
  | BlockDecl (decl_info, decl_list, decl_context_info, bdi),
    Some (outer_context, tp, procname, _), _ ->
      let func_decl = Block_decl_info (bdi, tp, outer_context) in
      let ms = build_method_signature decl_info procname func_decl true false in
      let extra_instrs = get_assume_not_null_calls ms bdi.bdi_parameters in
      ms, bdi.bdi_body, extra_instrs
  | _ -> raise Invalid_declaration

let method_signature_of_pointer class_name_opt pointer =
  try
    match Ast_utils.get_decl pointer with
    | Some meth_decl ->
        let ms, _, _ = method_signature_of_decl class_name_opt meth_decl None in
        Some ms
    | None -> None
  with Invalid_declaration -> None

let get_superclass_curr_class context =
  let retrive_super cname super_opt =
    let iname = Sil.TN_csu (Sil.Class, Mangled.from_string cname) in
    Printing.log_out "Checking for superclass = '%s'\n\n%!" (Sil.typename_to_string iname);
    match Sil.tenv_lookup (CContext.get_tenv context) iname with
    | Some Sil.Tstruct(_, _, _, _, (_, super_name):: _, _, _) ->
        Mangled.to_string super_name
    | _ ->
        Printing.log_err "NOT FOUND superclass = '%s'\n\n%!" (Sil.typename_to_string iname);
        (match super_opt with
         | Some super -> super
         | _ -> assert false) in
  match CContext.get_curr_class context with
  | CContext.ContextCls (cname, super_opt, _) ->
      retrive_super cname super_opt
  | CContext.ContextCategory (_, cls) ->
      retrive_super cls None
  | CContext.ContextNoCls
  | CContext.ContextProtocol _ -> assert false

let get_class_selector_instance context obj_c_message_expr_info act_params =
  let selector = obj_c_message_expr_info.Clang_ast_t.omei_selector in
  let pointer = obj_c_message_expr_info.Clang_ast_t.omei_decl_pointer in
  match obj_c_message_expr_info.Clang_ast_t.omei_receiver_kind with
  | `Class tp ->
      let sil_type = CTypes_decl.type_ptr_to_sil_type context.CContext.tenv tp in
      ((CTypes.classname_of_type sil_type), selector, pointer, MCStatic)
  | `Instance ->
      (match act_params with
       | (instance_obj, Sil.Tptr(t, _)):: _
       | (instance_obj, t):: _ ->
           (CTypes.classname_of_type t, selector, pointer, MCVirtual)
       | _ -> assert false)
  | `SuperInstance ->
      let superclass = get_superclass_curr_class context in
      (superclass, selector, pointer, MCNoVirtual)
  | `SuperClass ->
      let superclass = get_superclass_curr_class context in
      (superclass, selector, pointer, MCStatic)

let get_formal_parameters tenv ms =
  let rec defined_parameters pl =
    match pl with
    | [] -> []
    | (name, raw_type, _):: pl' ->
        let should_add_pointer name ms =
          let is_objc_self = name = CFrontend_config.self &&
                             CMethod_signature.ms_get_lang ms = CFrontend_config.OBJC in
          let is_cxx_this = name = CFrontend_config.this &&
                            CMethod_signature.ms_get_lang ms = CFrontend_config.CPP in
          (is_objc_self && CMethod_signature.ms_is_instance ms) || is_cxx_this in
        let tp = if should_add_pointer name ms then
            (Ast_expressions.create_pointer_type raw_type)
          else raw_type in
        let typ = CTypes_decl.type_ptr_to_sil_type tenv tp in
        (name, typ):: defined_parameters pl' in
  defined_parameters (CMethod_signature.ms_get_args ms)

let get_return_type tenv ms =
  let return_type = CMethod_signature.ms_get_ret_type ms in
  CTypes_decl.type_ptr_to_sil_type tenv return_type

let sil_func_attributes_of_attributes attrs =
  let rec do_translation acc al = match al with
    | [] -> list_rev acc
    | Clang_ast_t.SentinelAttr attribute_info:: tl ->
        let (sentinel, null_pos) = match attribute_info.Clang_ast_t.ai_parameters with
          | a:: b::[] -> (int_of_string a, int_of_string b)
          | _ -> assert false
        in
        do_translation (Sil.FA_sentinel(sentinel, null_pos):: acc) tl
    | _:: tl -> do_translation acc tl in
  do_translation [] attrs

let should_create_procdesc cfg procname defined generated =
  match Cfg.Procdesc.find_from_name cfg procname with
  | Some prevoius_procdesc ->
      let is_defined_previous = Cfg.Procdesc.is_defined prevoius_procdesc in
      let is_generated_previous =
        (Cfg.Procdesc.get_attributes prevoius_procdesc).ProcAttributes.is_generated in
      if defined &&
         ((not is_defined_previous) || (generated && is_generated_previous)) then
        (Cfg.Procdesc.remove cfg (Cfg.Procdesc.get_proc_name prevoius_procdesc) true;
         true)
      else false
  | None -> true

(** Creates a procedure description. *)
let create_local_procdesc cfg tenv ms fbody captured is_objc_inst_method =
  let defined = not ((list_length fbody) == 0) in
  let proc_name = CMethod_signature.ms_get_name ms in
  let pname = Procname.to_string proc_name in
  let attributes = sil_func_attributes_of_attributes (CMethod_signature.ms_get_attributes ms) in
  let is_generated = CMethod_signature.ms_is_generated ms in
  let create_new_procdesc () =
    let formals = get_formal_parameters tenv ms in
    let captured_str = list_map (fun (s, t, _) -> (Mangled.to_string s, t)) captured in
    (* Captured variables for blocks are treated as parameters *)
    let formals = captured_str @formals in
    let source_range = CMethod_signature.ms_get_loc ms in
    Printing.log_out "\nCreating a new procdesc for function: '%s'\n@." pname;
    let loc_start = CLocation.get_sil_location_from_range source_range true in
    let loc_exit = CLocation.get_sil_location_from_range source_range false in
    let ret_type = get_return_type tenv ms in
    let captured' = list_map (fun (s, t, _) -> (s, t)) captured in
    let procdesc =
      let proc_attributes =
        { (ProcAttributes.default proc_name Config.C_CPP) with
          ProcAttributes.captured = captured';
          formals;
          func_attributes = attributes;
          is_defined = defined;
          is_generated;
          is_objc_instance_method = is_objc_inst_method;
          loc = loc_start;
          ret_type;
        } in
      Cfg.Procdesc.create {
        Cfg.Procdesc.cfg;
        proc_attributes;
      } in
    if defined then
      (if !Config.arc_mode then
         Cfg.Procdesc.set_flag procdesc Mleak_buckets.objc_arc_flag "true";
       let start_kind = Cfg.Node.Start_node procdesc in
       let start_node = Cfg.Node.create cfg loc_start start_kind [] procdesc [] in
       let exit_kind = Cfg.Node.Exit_node procdesc in
       let exit_node = Cfg.Node.create cfg loc_exit exit_kind [] procdesc [] in
       Cfg.Procdesc.set_start_node procdesc start_node;
       Cfg.Procdesc.set_exit_node procdesc exit_node) in
  let generated = CMethod_signature.ms_is_generated ms in
  if should_create_procdesc cfg proc_name defined generated then
    (create_new_procdesc (); true)
  else false

(** Create a procdesc for objc methods whose signature cannot be found. *)
let create_external_procdesc cfg proc_name is_objc_inst_method type_opt =
  match Cfg.Procdesc.find_from_name cfg proc_name with
  | Some _ -> ()
  | None ->
      let ret_type, formals =
        (match type_opt with
         | Some (ret_type, arg_types) ->
             ret_type, list_map (fun typ -> ("x", typ)) arg_types
         | None -> Sil.Tvoid, []) in
      let loc = Location.dummy in
      let _ =
        let proc_attributes =
          { (ProcAttributes.default proc_name Config.C_CPP) with
            ProcAttributes.formals;
            is_objc_instance_method = is_objc_inst_method;
            loc;
            ret_type;
          } in
        Cfg.Procdesc.create {
          Cfg.Procdesc.cfg = cfg;
          proc_attributes = proc_attributes;
        } in
      ()

let create_procdesc_with_pointer context pointer class_name_opt name tp =
  let open CContext in
  match method_signature_of_pointer class_name_opt pointer with
  | Some callee_ms ->
      ignore (create_local_procdesc context.cfg context.tenv callee_ms [] [] false);
      CMethod_signature.ms_get_name callee_ms
  | None ->
      let callee_name =
        match class_name_opt with
        | Some class_name ->
            General_utils.mk_procname_from_cpp_method class_name name tp
        | None ->
            General_utils.mk_procname_from_function name None tp !CFrontend_config.language in
      create_external_procdesc context.cfg callee_name false None;
      callee_name

let instance_to_method_call_type instance =
  if instance then MCVirtual
  else MCStatic
