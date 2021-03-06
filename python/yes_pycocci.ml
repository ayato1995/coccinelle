(*
 * This file is part of Coccinelle, lincensed under the terms of the GPL v2.
 * See copyright.txt in the Coccinelle source code for more information.
 * The Coccinelle source code can be obtained at http://coccinelle.lip6.fr
 *)

open Ast_c
open Common
open Pycaml
open Pycocci_aux
module StringMap = Map.Make (String)

exception Pycocciexception

let python_support = true

(* ------------------------------------------------------------------- *)
(* The following definitions are from
http://patches.ubuntu.com/by-release/extracted/debian/c/coccinelle/0.1.5dbs-2/01-system-pycaml
as well as _pycocci_setargs *)

let _pycocci_none () =
  let builtins = pyeval_getbuiltins () in
  pyobject_getitem (builtins, pystring_fromstring "None")

let _pycocci_true () =
  let builtins = pyeval_getbuiltins () in
  pyobject_getitem (builtins, pystring_fromstring "True")

let _pycocci_false () =
  let builtins = pyeval_getbuiltins () in
  pyobject_getitem (builtins, pystring_fromstring "False")

let _pycocci_tuple6 (a,b,c,d,e,f) =
  pytuple_fromarray ([|a; b; c; d; e; f|])

(* ------------------------------------------------------------------- *)

let check_return_value msg v =
  if v = (pynull ()) then
	  (pyerr_print ();
	  Common.pr2 ("while " ^ msg ^ ":");
	  raise Pycocciexception)
  else ()
let check_int_return_value msg v =
  if v = -1 then
	  (pyerr_print ();
          Common.pr2 ("while " ^ msg ^ ":");
	  raise Pycocciexception)
  else ()

let initialised = ref false

let coccinelle_module = ref (_pycocci_none ())
let cocci_file_name = ref ""

(* dealing with python modules loaded *)
let module_map = ref (StringMap.add "__main__" (_pycocci_none ()) StringMap.empty)

let get_module module_name =
  StringMap.find module_name (!module_map)

let is_module_loaded module_name =
  try
    let _ = get_module module_name in
    true
  with Not_found -> false

let load_module module_name =
  if not (is_module_loaded module_name) then
    (* let _ = Sys.command("python3 -c 'import " ^ module_name ^ "'") in *)
    let m = pyimport_importmodule module_name in
    check_return_value ("importing module " ^ module_name) m;
    (module_map := (StringMap.add module_name m (!module_map));
    m)
  else get_module module_name
(* end python module handling part *)

(* python interaction *)
let split_fqn fqn =
  let last_period = String.rindex fqn '.' in
  let module_name = String.sub fqn 0 last_period in
  let class_name = String.sub fqn (last_period + 1) (String.length fqn - last_period - 1) in
  (module_name, class_name)

let pycocci_get_class_type fqn =
  let (module_name, class_name) = split_fqn fqn in
  let m = get_module module_name in
  let attr = pyobject_getattrstring(m, class_name) in
  check_return_value "obtaining a python class type" attr;
  attr

let pycocci_instantiate_class fqn args =
  let class_type = pycocci_get_class_type fqn in
  let obj =
    pyeval_callobjectwithkeywords(class_type, args, pynull()) in
  check_return_value "instantiating a python class" obj;
  obj

(* end python interaction *)

let inc_match = ref true
let exited = ref false

let include_match v =
  let truth = pyobject_istrue (pytuple_getitem (v, 1)) in
  check_int_return_value "testing include_match" truth;
  inc_match := truth != 0;
  _pycocci_none ()

let sp_exit _ =
  exited := true;
  _pycocci_none ()

let build_class cname parent fields methods pymodule =
  let cx =
    Pycaml.pyclass_init (pystring_fromstring cname)
      (pytuple_fromsingle (pycocci_get_class_type parent)) fields methods in
  let v = pydict_setitemstring(pymodule_getdict pymodule, cname, cx) in
  check_int_return_value ("adding python class " ^ cname) v;
  cx

let the_environment = ref []

let has_environment_binding name =
  let a = pytuple_toarray name in
  let (rule, name) = (Array.get a 1, Array.get a 2) in
  let orule = pystring_asstring rule in
  let oname = pystring_asstring name in
  let e = List.exists (function (x,y) -> orule = x && oname = y)
      !the_environment in
  if e then _pycocci_true () else _pycocci_false ()

let pyoption pyobject =
  if pyobject = pynone () then
    None
  else
    Some pyobject

let list_of_pylist pylist =
  Array.to_list (pylist_toarray pylist)

let string_list_of_pylist pylist =
  List.map pystring_asstring (list_of_pylist pylist)

let string_pair_of_pytuple pytuple =
  let s0 = pytuple_getitem (pytuple, 0) in
  let s1 = pytuple_getitem (pytuple, 1) in
  (pystring_asstring s0, pystring_asstring s1)

let add_pending_instance args =
  let py_files = pytuple_getitem (args, 1) in
  let py_virtual_rules = pytuple_getitem (args, 2) in
  let py_virtual_identifiers = pytuple_getitem (args, 3) in
  let py_extend_virtual_ids = pytuple_getitem (args, 4) in
  let files = Common.map_option string_list_of_pylist (pyoption py_files) in
  let virtual_rules = string_list_of_pylist py_virtual_rules in
  let virtual_identifiers =
    List.map string_pair_of_pytuple (list_of_pylist py_virtual_identifiers) in
  let extend_virtual_ids = py_is_true py_extend_virtual_ids in
  Iteration.add_pending_instance
    (files, virtual_rules, virtual_identifiers, extend_virtual_ids);
  pynone ()

let pycocci_init_not_called _ = failwith "pycocci_init() not called"

let pywrap_ast = ref pycocci_init_not_called

let pyunwrap_ast = ref pycocci_init_not_called

let wrap_make metavar_of_pystring args =
  let arg = pytuple_getitem (args, 1) in
  let s = pystring_asstring arg in
  let mv = metavar_of_pystring s in
  !pywrap_ast mv

let wrap_make_stmt_with_env args =
  let arg_env = pytuple_getitem (args, 1) in
  let arg_s = pytuple_getitem (args, 2) in
  let env = pystring_asstring arg_env in
  let s = pystring_asstring arg_s in
  let mv = Coccilib.make_stmt_with_env env s in
  !pywrap_ast mv

let wrap_make_listlen args =
  let arg = pytuple_getitem (args, 1) in
  let i = Pycaml.pyint_asint arg in
  let mv = Coccilib.make_listlen i in
  !pywrap_ast mv

let wrap_make_position args =
  let arg_fl = pytuple_getitem (args, 1) in
  let arg_fn = pytuple_getitem (args, 2) in
  let arg_startl = pytuple_getitem (args, 3) in
  let arg_startc = pytuple_getitem (args, 4) in
  let arg_endl = pytuple_getitem (args, 5) in
  let arg_endc = pytuple_getitem (args, 6) in
  let fl = pystring_asstring arg_fl in
  let fn = pystring_asstring arg_fn in
  let startl = Pycaml.pyint_asint arg_startl in
  let startc = Pycaml.pyint_asint arg_startc in
  let endl = Pycaml.pyint_asint arg_endl in
  let endc = Pycaml.pyint_asint arg_endc in
  let mv = Coccilib.make_position fl fn startl startc endl endc in
  !pywrap_ast mv

let pyoutputinstance = ref (_pycocci_none ())

let get_cocci_file args =
  pystring_fromstring (!cocci_file_name)

(* initialisation routines *)
let _pycocci_setargs argv0 =
  let argv =
    pysequence_list (pytuple_fromsingle (pystring_fromstring argv0)) in
  let sys_mod = load_module "sys" in
  pyobject_setattrstring (sys_mod, "argv", argv)

let pycocci_init () =
  (* initialize *)
  if not !initialised then (
  initialised := true;
  let _ = if not (py_isinitialized () != 0) then
  	(if !Flag.show_misc then Common.pr2 "Initializing python\n%!";
	py_initialize()) in

  (* set argv *)
  let argv0 = Sys.executable_name in
  let _ = _pycocci_setargs argv0 in

  coccinelle_module := (pymodule_new "coccinelle");
  module_map := StringMap.add "coccinelle" !coccinelle_module !module_map;
  let _ = load_module "coccilib.elems" in
  let _ = load_module "coccilib.output" in

  let module_dictionary = pyimport_getmoduledict() in
  coccinelle_module := pymodule_new "coccinelle";
  let mx = !coccinelle_module in
  let mypystring = pystring_fromstring !cocci_file_name in
  let cx = build_class "Cocci" (!Flag.pyoutput)
      [("cocci_file", mypystring)]
      [("exit", sp_exit);
	("include_match", include_match);
	("has_env_binding", has_environment_binding);
	("add_pending_instance", add_pending_instance);
	("make_ident", wrap_make Coccilib.make_ident);
	("make_expr", wrap_make Coccilib.make_expr);
	("make_stmt", wrap_make Coccilib.make_stmt);
	("make_stmt_with_env", wrap_make_stmt_with_env);
	("make_type", wrap_make Coccilib.make_type);
	("make_listlen", wrap_make_listlen);
	("make_position", wrap_make_position);
     ] mx in
  pyoutputinstance := cx;
  let v1 = pydict_setitemstring(module_dictionary, "coccinelle", mx) in
  check_int_return_value "adding coccinelle python module" v1;

  register_ocamlpill_types [|"metavar_binding_kind"|];
  let (wrap_ast, unwrap_ast) =
    make_pill_wrapping "metavar_binding_kind" Ast_c.MetaNoVal in
  pywrap_ast := wrap_ast;
  pyunwrap_ast := unwrap_ast;
  ()) else
  ()

(*let _ = pycocci_init ()*)
(* end initialisation routines *)

let default_hashtbl_size = 17

let added_variables = Hashtbl.create default_hashtbl_size

let build_classes env =
  let _ = pycocci_init () in
  inc_match := true;
  exited := false;
  the_environment := env;
  let mx = !coccinelle_module in
  let dict = pymodule_getdict mx in
  Hashtbl.iter
    (fun name () ->
      match name with
	"include_match" | "has_env_binding" | "exit" -> ()
      | name ->
	  let v = pydict_delitemstring(dict,name) in
	  check_int_return_value ("removing " ^ name ^ " from python coccinelle module") v)
    added_variables;
  Hashtbl.clear added_variables

let build_variable name value =
  let mx = !coccinelle_module in
  Hashtbl.replace added_variables name ();
  check_int_return_value ("build python variable " ^ name)
    (pydict_setitemstring(pymodule_getdict mx, name, value))

let get_variable name =
  let mx = !coccinelle_module in
  pystring_asstring
    (pyobject_str(pydict_getitemstring(pymodule_getdict mx, name)))

let contains_binding e (_,(r,m),_) =
  try
    let _ = List.find (function ((re, rm), _) -> r = re && m = rm) e in
    true
  with Not_found -> false

let construct_variables mv e =
  let find_binding (r,m) =
    try
      let elem = List.find (function ((re,rm),_) -> r = re && m = rm) e in
      Some elem
    with Not_found -> None
  in

(* Only string in this representation, so no point
  let instantiate_Expression(x) =
    let str = pystring_fromstring (Pycocci_aux.exprrep x) in
    pycocci_instantiate_class "coccilib.elems.Expression"
      (pytuple_fromsingle (str))
  in
*)

(* Only string in this representation, so no point
  let instantiate_Identifier(x) =
    let str = pystring_fromstring x in
    pycocci_instantiate_class "coccilib.elems.Identifier"
      (pytuple_fromsingle (str))
  in
*)

  let instantiate_term_list py printer lst  =
    let (str,elements) = printer lst in
    let str = pystring_fromstring str in
    let elements =
      pytuple_fromarray
	(Array.of_list (List.map pystring_fromstring elements)) in
    let repr =
      pycocci_instantiate_class "coccilib.elems.TermList"
	(pytuple_fromarray (Array.of_list [str;elements])) in
    let _ = build_variable py repr in () in

  List.iter (function (py,(r,m),_,init) ->
    match find_binding (r,m) with
      None ->
	(match init with
	  Ast_cocci.MVInitString s ->
            let _ = build_variable py (pystring_fromstring s) in
	    ()
	| Ast_cocci.MVInitPosList ->
	    let pylocs = pytuple_fromarray (Array.of_list []) in
	    let _ = build_variable py pylocs in
	    ()
	| Ast_cocci.NoMVInit ->
	    failwith "python variables should be bound")
(*    | Some (_, Ast_c.MetaExprVal (expr,_,_)) ->
       let expr_repr = instantiate_Expression(expr) in
       let _ = build_variable py expr_repr in
       () *)
  (*  | Some (_, Ast_c.MetaIdVal id) ->
       let id_repr = instantiate_Identifier(id) in
       let _ = build_variable py id_repr in
       () *)
    | Some (_, Ast_c.MetaExprListVal (exprlist)) ->
	instantiate_term_list py Pycocci_aux.exprlistrep exprlist
    | Some (_, Ast_c.MetaParamListVal (paramlist)) ->
	instantiate_term_list py Pycocci_aux.paramlistrep paramlist
    | Some (_, Ast_c.MetaInitListVal (initlist)) ->
	instantiate_term_list py Pycocci_aux.initlistrep initlist
    | Some (_, Ast_c.MetaFieldListVal (fieldlist)) ->
	instantiate_term_list py Pycocci_aux.fieldlistrep fieldlist
    | Some (_, Ast_c.MetaPosValList l) ->
       let locs =
	 List.map
	   (function (fname,current_element,(line,col),(line_end,col_end)) ->
		pycocci_instantiate_class "coccilib.elems.Location"
	       (_pycocci_tuple6
		(pystring_fromstring fname,pystring_fromstring current_element,
		pystring_fromstring (Printf.sprintf "%d" line),
		pystring_fromstring (Printf.sprintf "%d" col),
		pystring_fromstring (Printf.sprintf "%d" line_end),
		pystring_fromstring (Printf.sprintf "%d" col_end)))) l in
       let pylocs = pytuple_fromarray (Array.of_list locs) in
       let _ = build_variable py pylocs in
       ()
    | Some (_,binding) ->
       let _ =
	 build_variable py
	   (pystring_fromstring (Pycocci_aux.stringrep binding)) in
       ()
    ) mv;

  let add_string_literal s = build_variable s (pystring_fromstring s) in
  List.iter add_string_literal !Iteration.parsed_virtual_rules;
  List.iter add_string_literal !Iteration.parsed_virtual_identifiers

let construct_script_variables mv =
  List.iter
    (function (_,py) ->
      let str =
	pystring_fromstring
	  "initial value: consider using coccinelle.varname" in
      let _ = build_variable py str in
      ())
    mv

let retrieve_script_variables mv =
  let unwrap (_, py) =
    let mx = !coccinelle_module in
    let v = pydict_getitemstring (pymodule_getdict mx, py) in
    if pystring_check v then
      Ast_c.MetaIdVal(pystring_asstring v)
    else
      !pyunwrap_ast v in
  List.map unwrap mv

let set_coccifile cocci_file =
	cocci_file_name := cocci_file;
	()

let pyrun_simplestring s =
  let res = Pycaml.pyrun_simplestring s in
  check_int_return_value ("running simple python string:\n" ^ s) res;
  res

let py_isinitialized () =
  Pycaml.py_isinitialized ()


let py_finalize () =
  Pycaml.py_finalize ()
