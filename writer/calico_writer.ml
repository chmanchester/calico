open Printf
open List
open Ast

let rec range_list (i : int) (j : int) (acc : int list) : int list =
  if i > j then acc else range_list i (j - 1) (j :: acc)

let call_inner_function (procNum: int) (name: string) (kind: funKind) (ty: string)
                        (params: param_info list) (recover : bool) : string =
  let index = string_of_int procNum in
  let get_p_name = (fun p -> match p with (name, _) -> name) in
  let all_names = (map get_p_name params) in
  "// < call_inner_function\n        " ^
    begin match kind with
      | ArithmeticReturn        -> (if not recover then "*t_result" ^ index ^ " = " else "") ^ "__" ^ name ^
                       "(" ^ String.concat ", " all_names ^ ")"
      | VoidReturn  -> "__" ^ name ^ "(" ^ String.concat ", " all_names ^ ")"
      | PointerReturn -> ty ^ " temp_t_result = __" ^ name ^ "(" ^
        String.concat ", " all_names ^ ");\n        memcpy(t_result" ^ index ^
        ", temp_t_result, result_sizes[" ^ index ^ "])"
    end
  ^ ";\n// call_inner_function >\n"

let output_transformation (procNum: int) (return_type: string)
                          (prop: out_annot) (is_recovery: bool) : string =
  let index = string_of_int procNum in
  "// < output_transformation\n    " ^
    begin match (prop, return_type, is_recovery) with
      | (_, "void", _)   -> "    " ^ prop ^ ";\n"
      | ("id", _, true)  -> ";\n"
      | ("id", _, false) -> "memcpy(g_result" ^ index ^
        ", orig_result, result_sizes[" ^ index ^ "]);\n"
      |  _               -> return_type ^ "* temp_g_result" ^ index ^ " = " ^
        "malloc(" ^ "result_sizes[" ^ index ^ "]);\n" ^
        "    *temp_g_result" ^ index ^ " = " ^
        Str.global_replace (Str.regexp "result") "*orig_result" prop ^
        ";\n    memcpy(g_result" ^ index ^ ", temp_g_result" ^ index ^
        ", result_sizes[" ^ index ^ "]);"
    end
  ^ "\n    // output_transformation >\n"

let input_transformation (param : param_info) (prop : param_annot) : string =
  "// < input_transformation\n        " ^
    begin match (param, prop) with
      | ((param_name, ty), (name, inputs)) ->
        let prop_expr = name ^ "(" ^ (String.concat ", " inputs) ^ ")" in
        if String.compare param_name name = 0 || String.compare name "id" = 0
        then ""
        else param_name ^ " = " ^ prop_expr
    end
  ^ ";\n// input_transformation >"

let recover_t_result (procNum : int) (aset : annotation_set) : string =
  match aset with
    | ASet(_, _, Some(ptr, size, count), _) ->
      "        memcpy(t_result" ^ string_of_int procNum ^
        ", " ^ ptr ^ ", " ^ size ^ "*" ^ count ^ ");\n"
    | ASet(_, _, _, _)          -> ""


let transformed_call (f : annotated_comment) (procNum : int) : string =
  let index = string_of_int procNum in
  "    if (procNum == " ^ index ^ ") {\n" ^
    "        t_result" ^ index ^ " = shmat(shmids[" ^ index ^ "], NULL, 0);\n" ^
  begin match f with
    | AComm((name, kind, ty), params, asets) ->
        let aset = nth asets procNum in
        let (pAnnots, recover) = begin match aset with
          | ASet (pas, _, Some (_), _) -> (pas, true)
          | ASet (pas, _, None, _)     -> (pas, false)
        end in
        (* apply input transformations *)
        String.concat ";\n        "
          (map2 input_transformation params pAnnots) ^
        (* run inner function *)
        (call_inner_function procNum name kind ty params recover) ^
        (* recover result if necessary *)
        recover_t_result procNum aset ^
        (* clean up *)
        "        shmdt(t_result" ^ index ^ ");\n" ^ 
        "        exit(0);\n" ^
        "    }\n"
  end

let fprint_results (procNum : int) (fun_kind : funKind) (return_type : string) : string =
  (* let index = string_of_int procNum in *)
  let indicator = begin match return_type with
                  | "int"    -> "%d"
                  | "double" -> "%f"
                  | "float"  -> "%f"
                  | _        -> ""
                  end in
  begin match indicator with
  | "" -> ""
  | _  -> "" (* "        printf(\"g(f(x)): " ^ indicator ^ "\\nf(t(x)): " ^ indicator ^
          "\\n\", *g_result" ^ index ^ ", *t_result" ^ index ^ ");" *)
  end

let property_assertion (return_type : string) (fun_kind : funKind)
    (prop : annotation_set) (procNum : int) : string =
  let index = string_of_int procNum in
  begin match prop with
    | ASet(param_props, out_prop, recover, eq) ->
      let (elem_size, eqfun, count, is_recovery) = match (recover, eq) with
        | (None, _) -> ("sizeof(" ^ return_type ^ ")", "memcmp", "1", false)
        | (Some(_, expr, count), None) -> (expr, "memcmp", count, true)
        | (Some(_, expr, count), Some(eq)) -> (expr, eq, count, true)
      in

      "    t_result" ^ index ^ " = shmat(shmids[" ^ index ^ "], NULL, 0);\n    " ^
        output_transformation procNum return_type out_prop is_recovery ^

      begin match recover with
        | None                 -> ""
        | Some(ptr, _, count)  -> "    memcpy(g_result" ^ string_of_int procNum ^
          ", " ^ ptr ^ ", " ^ elem_size ^ "*" ^ count ^ ");\n"
      end

        (* Write out a loop to call the appropriate equality function on each
           member of the memory block to be processed *)
      ^ "    for (i = 0; i < " ^ count ^ "; i++) {\n" ^
        "      if (" ^ eqfun ^ "(g_result" ^ index ^ " + (i*" ^ elem_size ^ "), " ^
        "t_result" ^ index ^ " + (i*" ^ elem_size ^ ")" ^ 
      (if eqfun = "memcmp" then ", " ^ elem_size else "") ^ ")) {\n" ^
        "        printf(\"a property has been violated:\\ninput_prop: " ^
        (String.concat ", " (map name_of_param_annot param_props)) ^
        "\\noutput_prop: " ^ out_prop ^ "\\n\");\n" ^
        "        exit(1);\n" ^
        fprint_results procNum fun_kind return_type ^
        "      }\n" ^
        "    }\n"
  end

let unstar (type_str : string) : string =
  Str.global_replace (Str.regexp "*") "" type_str

let initialize_tg_results (default : string) (set : annotation_set) (procNum : int) : string =
  let (size_expr, typ) = begin match set with
    | ASet(_, _, Some (_, size, count), _) -> (size ^ "*" ^ count, "void")
    | ASet(_, _, _, _)           -> ("sizeof(" ^ default ^ ")", unstar default)
  end in
  let index = string_of_int procNum in
  "result_sizes[" ^ index ^ "] = " ^ size_expr ^ ";\n    " ^
    typ ^ "* t_result" ^ index ^ " = NULL;\n    " ^
    typ ^ "* g_result" ^ index ^ " = malloc(result_sizes[" ^ index ^ "]);\n"

let call_original (k: funKind) (ty: string) (call_to_inner: string) : string =
  begin match k with
    | ArithmeticReturn        -> "*orig_result = __" ^ call_to_inner
    | PointerReturn -> ty ^ "temp_orig_result = malloc(sizeof(" ^ (unstar ty) ^ "));\n    " ^
      "temp_orig_result = __" ^ call_to_inner ^
      ";\n        memcpy(orig_result, temp_orig_result, sizeof(" ^
      (unstar ty) ^ "))"
    | VoidReturn  -> "__" ^ call_to_inner
  end

let instrument_function (f : program_element) : string =
  begin match f with
    | ComStr(s) -> "/*\n" ^ s ^ "*/\n"
    | SrcStr(s) -> s
    | AFun (AComm((name, k, ty), params, asets) as acomm, header, funbody) ->
      (* each child process will have a number *)
      let child_indexes = (range_list 0 ((length asets) - 1) []) in
      let call_to_inner = name ^ "(" ^ String.concat ", " (map fst params) ^ ")" in
      (* original version of the function with underscores *)
      ty ^ " __" ^ name ^ header ^ funbody ^ "\n\n" ^
        (* instrumented version *)
        ty ^ " " ^ name ^ header ^ " {\n" ^
        "    int numProps = " ^ string_of_int (length asets) ^ ";\n" ^
        "    size_t result_sizes[numProps];\n" ^

        (* fork *)

        "    int* shmids = malloc(numProps * sizeof(int));\n" ^
        "    int procNum = -1;\n" ^ (* -1 for parent, 0 and up for children *)
        "    int i;\n" ^

        (* TODO: how to initialize for a pure struct return type? *)
        (match k with
          | VoidReturn -> ""
          | _          -> "    " ^ (unstar ty) ^
            " *orig_result = malloc(sizeof(" ^ (unstar ty) ^ "));") ^
        "\n    " ^ String.concat "\n    "
        (map2 (initialize_tg_results (unstar ty)) asets child_indexes) ^

        "\n" ^
        "    for (i = 0; i < numProps; i += 1) {\n" ^
        "        if (procNum == -1) {\n" ^
        "            if ((shmids[i] = shmget(key++, result_sizes[i], IPC_CREAT | 0666)) < 0) {\n" ^
        "                perror(\"shmget\");\n" ^
        "                exit(1);\n" ^
        "            }\n" ^
        "            if (0 == fork()) {\n" ^
        "                procNum = i;\n" ^
        "                break;\n" ^
        "            }\n" ^
        "        }\n" ^
        "    }\n\n" ^

        (* parent runs original inputs and waits for children *)
        "    if (procNum == -1) {\n        " ^
        (call_original k ty call_to_inner)
        ^ ";\n        for (i = 0; i < numProps; i += 1) {\n" ^
        "            wait(NULL);\n" ^
        "        }\n" ^
        "    }\n\n" ^
        (* children run transformed inputs and record the result in shared memory *)
        String.concat "\n" (map (transformed_call acomm) child_indexes) ^ "\n" ^

        (* make assertions about the results *)
        String.concat "\n" (map2 (property_assertion ty k) asets child_indexes) ^ "\n" ^

        (* cleanup *)
        "    for (i = 0; i < numProps; i++) {\n" ^
        "        if (shmctl(shmids[i], IPC_RMID, NULL) < 0) {\n" ^
        "            perror(\"shmctl\");\n" ^
        "        }\n" ^
        "    }\n" ^
      String.concat "\n" (map (fun i -> "    shmdt(t_result" ^ (string_of_int i) ^ ");")
                            child_indexes) ^ "\n" ^
        "    free(shmids);\n" ^
        "    return " ^ 
        (match k with
          | VoidReturn       -> ""
          | ArithmeticReturn -> "*orig_result"
          | PointerReturn    -> "orig_result") ^
        ";\n" ^ "}"
  end

let rec name_out_path (modif : string) (path : string list) : string =
  begin match path with
    | []      -> raise (Failure "bad path")
    | [x]     -> modif ^ x
    | x :: xs -> x ^ "/" ^ (name_out_path modif xs)
  end

let write_source (sut: sourceUnderTest) : unit =
  (* TODO: actually implement indentation tracking instead of just guessing *)
  let path = Str.split (Str.regexp "/") sut.file_name in
  let out = open_out (name_out_path "calico_gen_" path) in
  fprintf out "#include \"calico_prop_library.h\"\n%s\n"
    (String.concat "\n" (map instrument_function sut.elements));
  close_out out;
