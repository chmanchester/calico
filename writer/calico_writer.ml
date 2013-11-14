open Printf
open List
open Ast

let key_number : string = "9847"

let rec repeat (s : string) (n : int) : string =
    if n <= 1 then s else s ^ (repeat s (n - 1))

let fst (tup : 'a * 'b) : 'a =
    begin match tup with
    | (x, _) -> x
    end

let snd (tup : 'a * 'b) : 'b =
    begin match tup with
    | (_, x) -> x
    end

let lbr (indent : int) : string =
    ";\n" ^ (repeat "    " indent)

let rec range_list (i : int) (j : int) (acc : int list) : int list =
    if i > j then acc else range_list i (j - 1) (j :: acc)

let rec merge (l1:'a list) (l2:'a list) : 'a list =
    begin match (l1, l2) with
    | ([], []) -> []
    | ([], l) -> l
    | (l, []) -> l
    | ((n1 :: rest1), (n2 :: rest2)) -> n1 :: n2 :: (merge rest1 rest2)
    end ;;

let write_param (param : param_info) : string =
  match param with
    | (name, TyStr(ty)) -> ty ^ " " ^ name

let input_transformation (param : parameter) (prop : (string * funKind)) : string =
    "// < input_transformation\n        " ^
    begin match prop with
    | (prop_name, Pure)        -> (if param.param_name = prop_name then "" 
                                   else param.param_name ^ " = " ^ prop_name)
    | (prop_name, SideEffect)  -> prop_name
    | (prop_name, PointReturn) -> param.param_type ^ " *temp_" ^ param.param_name ^ " = " ^
                                  prop_name ^ ";\n        memcpy(" ^ param.param_name ^
                                  ", temp_" ^ param.param_name ^ ", sizeof (" ^ param.param_type ^
                                  "))"
    end
    ^ ";\n// input_transformation >"

let call_inner_function (return_type : string) (fun_kind : funKind)
                        (fun_name : string) (params : parameter list) : string =
    let get_p_name (param : parameter) : string = param.param_name in
    let all_names = (map get_p_name params) in
    "// < call_inner_function\n        " ^
    begin match fun_kind with
    | Pure        -> "*result = __" ^ fun_name ^ "(" ^ String.concat ", " all_names ^ ")"
    | SideEffect  -> "__" ^ fun_name ^ "(" ^ String.concat ", " all_names ^ ")"
    | PointReturn -> return_type ^ " temp_f_result = __" ^ fun_name ^ "(" ^
        String.concat ", " all_names ^ ");\n        memcpy(result, temp_f_result, result_size)"
    end
    ^ ";\n// call_inner_function >\n"

let deref_var (s : string) (v : string) : string =
    Str.global_replace (Str.regexp v) ("*" ^ v) s

let output_transformation (return_type : string) (prop : (string * funKind)): string =
    "// < output_transformation\n        " ^
    begin match prop with
    | (prop_name, Pure)        -> "*result = " ^ (deref_var prop_name "result")
    | (prop_name, SideEffect)  -> prop_name
    | (prop_name, PointReturn) -> return_type ^ " *temp_g_result = " ^ prop_name ^
                                  ";\n        memcpy(result, temp_g_result, sizeof(" ^
                                  return_type ^ "))"
    end
    ^ ";\n// output_transformation >\n"

let transformed_call (f : annotatedFunction) (procNum : int) : string =
    "    if (procNum == " ^ (string_of_int procNum) ^ ") {\n" ^
    "        int shmid = shmget(key + procNum, result_size, 0666);\n" ^
    "        result = shmat(shmid, NULL, 0);\n" ^ 
    (* apply input transformations *)
    String.concat ";\n        "
    (map2 input_transformation f.parameters (nth f.properties procNum).input_prop) ^ ";\n" ^
    (* run inner function *)
    (call_inner_function f.return_type f.fun_kind f.fun_name f.parameters) ^
    (* apply output transformations *)
    output_transformation f.return_type (nth f.properties procNum).output_prop ^ 
    "        shmdt(result);\n" ^
    "        return 0;\n" ^
    "    }\n"

let property_assertion (fun_kind : funKind) (prop : property) (procNum : int) : string =
    "    result = shmat(shmids[" ^ (string_of_int procNum) ^ "], NULL, 0);\n    if (" ^
    (* TODO: for compound data types, we need the tester to supply a notion of equality *)
    begin match fun_kind with
    | Pure        -> ""
    | PointReturn -> "*"
    | SideEffect  -> ""
    end
    ^ "orig_result != *result) {\n" ^
        "        printf(\"a property has been violated:\\ninput_prop: " ^ 
        (String.concat ", " (map fst prop.input_prop)) ^
            "\\noutput_prop: " ^ fst prop.output_prop ^ "\");\n" ^
    "    }\n"

let instrument_function (f : program_element) : string =

    begin match f with
    | ComStr(s) -> s
    | SrcStr(s) -> s
    | AFun (AComm(comm_text, (name, k, TyStr(ty)), params, apairs),
            funbody) ->

    (* each child process will have a number *)
    let child_indexes = (range_list 0 ((length apairs) - 1) []) in
    let call_to_inner = name ^ "(" ^ String.concat ", "
     (map fst params) in
    let param_decl = "(" ^ String.concat ", " (map write_param params) ^ ")" in
    (* original version of the function with underscores *)
    ty ^ " __" ^ name ^ param_decl ^ funbody ^ "\n\n" ^
    (* instrumented version *)
    comm_text ^ "\n" ^ ty ^ " " ^ name ^ param_decl ^ " {\n" ^

    (* fork *)
    "    int key = " ^ key_number ^ ";\n" ^ (* why this number? *)
    "    size_t result_size = sizeof(" ^ ty ^ ");\n" ^
    "    int numProps = " ^ string_of_int (length apairs) ^ ";\n" ^
    "    int* shmids = malloc(numProps * sizeof(int));\n" ^
    "    int procNum = -1;\n" ^ (* -1 for parent, 0 and up for children *)
    "    int i;\n" ^
    "    " ^ ty ^ " orig_result = " ^
    (if k = PointReturn then "NULL" else "0") ^
    ";\n    " ^ ty ^ 
    begin match k with
    | Pure -> "* result = 0"
    | SideEffect -> ""
    | PointReturn -> " result = NULL"
    end
    ^ ";\n\n" ^
    "    for (i = 0; i < numProps; i += 1) {\n" ^
    "        if (procNum == -1) {\n" ^
    "            shmids[i] = shmget(key + i, result_size, IPC_CREAT | 0666);\n" ^
    "            fork();\n" ^
    "            procNum = i;\n" ^
    "        } else {\n" ^
    "            break;\n" ^
    "        }\n" ^
    "    }\n\n" ^

    (* parent runs original inputs and waits for children *)
    "    if (procNum == -1) {\n        " ^
    begin match k with
    | Pure        -> "orig_result = __" ^ call_to_inner
    | PointReturn -> ty ^ " temp_orig_result = __" ^ call_to_inner ^
                     ");\n        memcpy(orig_result, temp_orig_result, sizeof(" ^ ty ^
                     ")"
    | SideEffect  -> call_to_inner
    end
     ^ ");\n        for (i = 0; i < numProps; i += 1) {\n" ^
    "            wait(NULL);\n" ^
    "        }\n" ^
    "    }\n\n" ^

    (* children run transformed inputs and transform the result *)
    String.concat "\n" (map (transformed_call f) child_indexes) ^ "\n" ^

    (* make assertions about the results *)
    String.concat "\n" (map2 (property_assertion k) apairs child_indexes) ^ "\n" ^

    (* cleanup *)
    "    free(shmids);\n" ^
    "    return orig_result;\n" ^
    "}"
    end

let write_source (sut: sourceUnderTest) : unit =
    (* TODO: actually implement indentation tracking instead of just guessing *)
    let out = open_out ("calico_" ^ sut.file_name ^ ".c") in
        fprintf out "#include \"calico_prop_library.h\"\n%s\nint main () {\nreturn 0;\n}\n"
        String.concat "\n\n" map instrument_function sut.elements
        close_out out;