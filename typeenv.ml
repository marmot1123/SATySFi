open Types

exception TypeCheckError of string

type type_variable_id = int
type type_environment = (var_name * type_struct) list
and type_struct =
  | TypeEnvironmentType of code_range * type_environment
  | UnitType     of code_range
  | IntType      of code_range
  | StringType   of code_range
  | BoolType     of code_range
  | FuncType     of code_range * type_struct * type_struct
  | ListType     of code_range * type_struct
  | RefType      of code_range * type_struct
  | ForallType   of type_variable_id * type_struct
  | TypeVariable of code_range * type_variable_id

(* !!!! ---- global variable ---- !!!! *)
let global_tyenv : type_environment ref = ref []

(* !!!! ---- global variable ---- !!!! *)
let global_env : environment = Hashtbl.create 32


let rec string_of_ast ast =
  match ast with
  | LambdaAbstract(x, m)         -> "(" ^ x ^ " -> " ^ (string_of_ast m) ^ ")"
  | FuncWithEnvironment(x, m, _) -> "(" ^ x ^ " *-> " ^ (string_of_ast m) ^ ")"
  | ContentOf(v)           -> "#" ^ v ^ "#"
  | Apply(m, n)            -> "(" ^ (string_of_ast m) ^ " " ^ (string_of_ast n) ^ ")"
  | Concat(s, t)           -> (string_of_ast s) ^ (string_of_ast t)
  | StringEmpty            -> ""
  | StringConstant(sc)     -> "{" ^ sc ^ "}"
  | NumericConstant(nc)    -> string_of_int nc
  | BooleanConstant(bc)    -> string_of_bool bc
  | IfThenElse(b, t, f)    ->
      "(if " ^ (string_of_ast b) ^ " then " ^ (string_of_ast t) ^ " else " ^ (string_of_ast f) ^ ")"
  | IfClassIsValid(t, f)   -> "(if-class-is-valid " ^ (string_of_ast t) ^ " else " ^ (string_of_ast f) ^ ")"
  | Reference(a)           -> "!" ^ (string_of_ast a)
  | ReferenceFinal(vn)     -> "!!" ^ vn
  | Overwrite(vn, n)       -> "(" ^ vn ^ " <- " ^ (string_of_ast n) ^ ")"
  | MutableValue(mv)       -> "(mutable " ^ (string_of_ast mv) ^ ")"
  | UnitConstant           -> "()"
  | LetMutableIn(vn, d, f) -> "(let-mutable " ^ vn ^ " <- " ^ (string_of_ast d) ^ " in " ^ (string_of_ast f) ^ ")"
  | _ -> "..."


(* untyped_abstract_tree -> code_range *)
let get_range utast =
  let (rng, _) = utast in rng

let get_range_from_type tystr =
  match tystr with
  | IntType(rng)         -> rng
  | StringType(rng)      -> rng
  | BoolType(rng)        -> rng
  | UnitType(rng)        -> rng
  | TypeVariable(rng, _) -> rng
  | FuncType(rng, _, _)  -> rng
  | ListType(rng, _)     -> rng
  | RefType(rng, _)      -> rng
  | TypeEnvironmentType(rng, _) -> rng
  | ForallType(_, _)     -> (-64, 0, 0, 0)

let describe_position (sttln, sttpos, endln, endpos) =
  if sttln == endln then
    "line " ^ (string_of_int sttln) ^ ", characters " ^ (string_of_int sttpos)
      ^ "-" ^ (string_of_int endpos)
  else
    "line " ^ (string_of_int sttln) ^ ", character " ^ (string_of_int sttpos)
      ^ " to line " ^ (string_of_int endln) ^ ", character " ^ (string_of_int endpos)

let error_reporting rng errmsg =
  let (sttln, sttpos, endln, endpos) = rng in
    if sttln == endln then
      "at line " ^ (string_of_int sttln) ^ ", characters "
        ^ (string_of_int sttpos) ^ "-" ^ (string_of_int endpos) ^ ":\n"
        ^ "    " ^ errmsg
    else
      "at line " ^ (string_of_int sttln) ^ ", character " ^ (string_of_int sttpos)
        ^ " to line " ^ (string_of_int endln) ^ ", character " ^ (string_of_int endpos) ^ ":\n"
        ^ "    " ^ errmsg

let rec string_of_type_struct tystr =
  match tystr with
  | StringType(_) -> "string"
  | IntType(_)    -> "int"
  | BoolType(_)   -> "bool"
  | UnitType(_)   -> "unit"
  | TypeEnvironmentType(_, _) -> "env"
  | FuncType(_, tydom, tycod) -> "(" ^ (string_of_type_struct tydom) ^ " -> " ^ (string_of_type_struct tycod) ^ ")"
  | ListType(_, tycont)       -> "(" ^ (string_of_type_struct tycont) ^ " list)"
  | RefType(_, tycont)        -> "(" ^ (string_of_type_struct tycont) ^ " ref)"
  | TypeVariable(_, tvid)     -> "'" ^ (string_of_int tvid)
  | ForallType(tvid, tycont)  -> "(forall '" ^ (string_of_int tvid) ^ ". " ^ (string_of_type_struct tycont) ^ ")"
(*
let rec string_of_type_environment tyenv =
  match tyenv with
  | []               -> ""
  | (vn, ts) :: tail -> "  " ^ vn ^ ": " ^ (string_of_type_struct ts) ^ "\n" ^ (string_of_type_environment tail)
*)

let rec found_in_list tvid lst =
  match lst with
  | []       -> false
  | hd :: tl -> if hd == tvid then true else found_in_list tvid tl

let rec found_in_type_struct tvid tystr =
  match tystr with
  | TypeVariable(_, tvidx)    -> tvidx == tvid
  | FuncType(_, tydom, tycod) -> (found_in_type_struct tvid tydom) || (found_in_type_struct tvid tycod)
  | ListType(_, tycont)       -> found_in_type_struct tvid tycont
  | RefType(_, tycont)        -> found_in_type_struct tvid tycont
  | _                         -> false

let rec found_in_type_environment tvid tyenv =
  match tyenv with
  | []                 -> false
  | (_, tystr) :: tail ->
      if found_in_type_struct tvid tystr then
        true
      else
        found_in_type_environment tvid tail


let unbound_id_list : type_variable_id list ref = ref []

(* type_struct -> type_environment -> (type_variable_id list) -> unit *)
let rec listup_unbound_id tystr tyenv =
  match tystr with
  | TypeVariable(_, tvid)     ->
    ( (* print_string ("%listup_unbound_id: '" ^ (string_of_int tvid) ^ "\n") ; *)
      if found_in_type_environment tvid tyenv then ()
      else if found_in_list tvid !unbound_id_list then ()
      else unbound_id_list := tvid :: !unbound_id_list
    )
  | FuncType(_, tydom, tycod) -> ( listup_unbound_id tydom tyenv ; listup_unbound_id tycod tyenv )
  | ListType(_, tycont)       -> listup_unbound_id tycont tyenv
  | RefType(_, tycont)        -> listup_unbound_id tycont tyenv
  | _                         -> ()

(* type_variable_id list -> type_struct -> type_struct *)
let rec add_forall_struct lst tystr =
  (* print_string "%add_forall_struct\n" ; *)
  match lst with
  | []           -> tystr
  | tvid :: tail -> ForallType(tvid, add_forall_struct tail tystr)

(* type_struct -> type_environment -> type_struct *)
let make_forall_type tystr tyenv =
(*	print_string ("%make_forall_type\n" ^ (string_of_type_environment tyenv) ^ "\n") ; *)
	unbound_id_list := [] ; listup_unbound_id tystr tyenv ;
	add_forall_struct (!unbound_id_list) tystr


let empty = []

let rec add tyenv varnm tystr =
  match tyenv with
  | []               -> [(varnm, tystr)]
  | (vn, ts) :: tail -> if vn == varnm then (varnm, tystr) :: tail else (vn, ts) :: (add tail varnm tystr)

let rec find tyenv varnm =
  match tyenv with
  | []               -> raise Not_found
  | (vn, ts) :: tail -> if vn = varnm then ts else find tail varnm
