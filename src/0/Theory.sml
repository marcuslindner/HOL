(* ========================================================================= *)
(* FILE          : Theory.sml                                                *)
(* DESCRIPTION   : Management of logical theories.                           *)
(*                                                                           *)
(* AUTHOR        : Konrad Slind, University of Calgary                       *)
(*                 (also T.U. Munich and Cambridge)                          *)
(* DATE          : September 11, 1991                                        *)
(* REVISION      : August 7, 1997                                            *)
(*               : March 9, 1998                                             *)
(*               : August 2000                                               *)
(*                                                                           *)
(* ========================================================================= *)

(*---------------------------------------------------------------------------

     Notes on the design. 

  We provide a single current theory segment, which can be thought of as 
  a scratchpad for building the segment that eventually gets exported. 
  The following are the important components of a segment:

      - mini-signatures for the types and terms declared in the current
        segment 

      - the unique id for the theory, along with its parents, which 
        should be already-loaded theory segments.

      - the theory graph, used to enforce a prohibition on circular 
        dependencies among segments.

      - the axioms, definitions, and theorems stored in the segment so far.

      - the status of the segment: is it consistent with disk (obscure),
        have items been deleted from the segment?

  The mini-signatures are held in Type.TypeSig and Term.TermSig, 
  along with all the types and terms declared in ancestor theories.
  
  The parents of the segment are held in the theory graph.

  When a segment is exported, we dump everything in it to a text file
  representing an ML structure. 

  Elements in the current segment can be deleted or overwritten, which
  makes consistency maintenance an issue.

 ---------------------------------------------------------------------------*)


structure Theory : RawTheory =
struct

open Feedback Lib KernelTypes ;

type ppstream = Portable.ppstream
type pp_type  = ppstream -> hol_type -> unit
type pp_thm   = ppstream -> thm -> unit

infix ##;

val ERR  = mk_HOL_ERR "Theory";
val WARN = HOL_WARNING "Theory";

type thy_addon = {sig_ps    : (ppstream -> unit) option,
                  struct_ps : (ppstream -> unit) option}


(* This reference is set in course of loading the parsing library *)

val pp_thm = ref (fn _:ppstream => fn _:thm => ())

(*---------------------------------------------------------------------------*
 * Unique identifiers, for securely linking a theory to its parents when     *
 * loading from disk.                                                        *
 *---------------------------------------------------------------------------*)

abstype thyid = UID of {name:string, timestamp:Time.time}
with
  fun thyid_eq x (y:thyid) = (x=y);
  fun new_thyid s = UID{name=s, timestamp=Portable.timestamp()};

  fun dest_thyid (UID{name, timestamp}) =
    let val {sec,usec} = Portable.dest_time(timestamp)
    in (name,sec,usec) end;

  val thyid_name = #1 o dest_thyid;

  local val mk_time = Portable.mk_time
  in fun make_thyid(s,i1,i2) = UID{name=s, timestamp=mk_time{sec=i1,usec=i2}}
  end;

  fun thyid_to_string (UID{name,timestamp}) = 
     String.concat["(",Lib.quote name,",",Time.toString timestamp,")"]

  val min_thyid = UID{name="min",timestamp=Time.zeroTime};    (* Ur-theory *)

end;

fun thyid_assoc x [] = raise ERR "thyid_assoc" "not found"
  | thyid_assoc x ((a,b)::t) = if thyid_eq x a then b else thyid_assoc x t;

fun thyname_assoc x [] = raise ERR "thyname_assoc" "not found"
  | thyname_assoc x ((a,b)::t) = if x = thyid_name a then b 
                                 else thyname_assoc x t;


(*---------------------------------------------------------------------------
    The theory graph is quite basic: just a list of pairs (thyid,parents).
    The "min" theory is already installed; it has no parents.
 ---------------------------------------------------------------------------*)

structure Graph = struct type graph = (thyid * thyid list) list
local val theGraph = ref [(min_thyid,[])]
in
   fun add p = theGraph := (p :: !theGraph)
   fun add_parent (n,newp) = 
     let fun same (node,_) = thyid_eq node n
         fun addp(node,parents) = (node, op_union thyid_eq [newp] parents)
         fun ins (a::rst) = if same a then addp a::rst else a::ins rst
           | ins [] = raise ERR "Graph.add_parent.ins" "not found"
     in theGraph := ins (!theGraph)
     end
   fun isin n = Lib.can (thyid_assoc n) (!theGraph);
   fun parents_of n = thyid_assoc n (!theGraph);
   fun ancestryl L =
    let fun Anc P Q = rev_itlist 
           (fn nde => fn A => if op_mem thyid_eq nde A then A
             else Anc (parents_of nde handle HOL_ERR _ => []) (nde::A)) P Q
    in Anc L []
    end;
   fun fringe () =
     let val all_parents = List.map #2 (!theGraph)
         fun is_parent y = Lib.exists (Lib.op_mem thyid_eq y) all_parents
     in List.filter (not o is_parent) (List.map #1 (!theGraph))
     end;
   fun first P = Lib.first P (!theGraph)
end
end; (* structure Graph *)


(*---------------------------------------------------------------------------*
 * A type for distinguishing the different kinds of theorems that may be     *
 * stored in a theory.                                                       *
 *---------------------------------------------------------------------------*)

datatype thmkind = Thm of thm | Axiom of string ref * thm | Defn of thm

fun is_axiom (Axiom _) = true  | is_axiom _   = false;
fun is_theorem (Thm _) = true  | is_theorem _ = false;
fun is_defn (Defn _)   = true  | is_defn _    = false;

fun drop_thmkind (Axiom(_,th)) = th
  | drop_thmkind (Thm th)      = th
  | drop_thmkind (Defn th)     = th;

fun drop_pthmkind (s,th) = (s,drop_thmkind th);

fun drop_Axkind (Axiom rth) = rth
  | drop_Axkind    _        = raise ERR "drop_Axkind" "";


(*---------------------------------------------------------------------------*
 * The type of HOL theory segments. Lacks fields for the type and term       *
 * signatures, which are held locally in the Type and Term structures.       *
 * Also lacks a field for the theory graph, which is held in Graph.          *
 *---------------------------------------------------------------------------*)

type segment = {thid  : thyid,                                 (* unique id  *)
                facts : (string * thmkind) list,    (* stored ax,def,and thm *)
                con_wrt_disk : bool,                (* consistency with disk *)
                overwritten  : bool,                   (* parts overwritten? *)
                adjoin       : thy_addon list}         (*  extras for export *)


(*---------------------------------------------------------------------------*
 *                 CREATE THE INITIAL THEORY SEGMENT.                        *
 *                                                                           *
 * The timestamp for a segment is its creation date. "con_wrt_disk" is       *
 * set to false because when a segment is created no corresponding file      *
 * gets created (the file is only created on export).                        *
 *---------------------------------------------------------------------------*)

fun fresh_segment s :segment =
   {thid=new_thyid s,  facts=[],
    con_wrt_disk=false, overwritten=false, adjoin=[]};


local val CT = ref (fresh_segment "scratch")
in
  fun theCT() = !CT
  fun makeCT seg = CT := seg
end;

val CTname = thyid_name o #thid o theCT;
val current_theory = CTname;


(*---------------------------------------------------------------------------*
 *                  READING FROM THE SEGMENT                                 *
 *---------------------------------------------------------------------------*)

fun thy_types thyname               = Type.thy_types thyname
fun thy_constants thyname           = Term.thy_consts thyname
fun thy_parents thyname             = snd (Graph.first 
                                           (equal thyname o thyid_name o fst))
fun thy_axioms (th:segment)         = filter (is_axiom o #2)   (#facts th)
fun thy_theorems (th:segment)       = filter (is_theorem o #2) (#facts th)
fun thy_defns (th:segment)          = filter (is_defn o #2)    (#facts th)
fun thy_addons (th:segment)         = #adjoin th
fun thy_con_wrt_disk n (th:segment) = #con_wrt_disk th;


local fun norm_name "-" = CTname() 
        | norm_name s = s
      fun grab_item style name alist =
        case Lib.assoc1 name alist
         of SOME (_,th) => th
          | NONE => raise ERR style 
                      ("couldn't find "^style^" named "^Lib.quote name)
in
 val types            = thy_types o norm_name
 val constants        = thy_constants o norm_name
 fun get_parents s    = if norm_name s = CTname() 
                         then Graph.fringe() else thy_parents s
 val parents          = map thyid_name o get_parents
 val ancestry         = map thyid_name o Graph.ancestryl o get_parents
 fun current_axioms() = map drop_pthmkind (thy_axioms (theCT()))
 fun current_theorems() = map drop_pthmkind (thy_theorems (theCT()))
 fun current_definitions() = map drop_pthmkind (thy_defns (theCT()))
end;

   
(*---------------------------------------------------------------------------*
 * Is a segment empty?                                                       *
 *---------------------------------------------------------------------------*)

fun empty_segment ({thid,facts, ...}:segment) =
  let val thyname = thyid_name thid
  in null (thy_types thyname) andalso
     null (thy_constants thyname) andalso
     null facts
  end;

(*---------------------------------------------------------------------------*
 *              ADDING TO THE SEGMENT                                        *
 *---------------------------------------------------------------------------*)

fun add_type {name,theory,arity}
             {thid,facts,con_wrt_disk,overwritten,adjoin} =
   {thid=thid, facts=facts, con_wrt_disk=con_wrt_disk, adjoin=adjoin,
    overwritten = let open Type
                  in case TypeSig.insert (mk_id(name,theory),arity)
                      of TypeSig.INITIAL _ => overwritten
                       | TypeSig.CLOBBER _ => true
                  end};

fun add_term {name,theory,htype} 
             {thid,facts,con_wrt_disk,overwritten,adjoin}
  = {thid=thid,facts=facts, con_wrt_disk=con_wrt_disk, adjoin=adjoin,
     overwritten = 
      let open Term 
          val tykind = (if Type.polymorphic htype then POLY else GRND) htype
      in case TermSig.insert (Const(mk_id(name,theory),tykind))
          of TermSig.INITIAL _ => overwritten
           | TermSig.CLOBBER _ => true
      end};

local fun pluck1 x L =
        let fun get [] A = NONE
              | get ((p as (x',_))::rst) A =
                if x=x' then SOME (p,rst@A) else get rst (p::A)
        in get L []
        end
      fun overwrite (p as (s,f)) l =
       case pluck1 s l
        of NONE => (p::l, false)
         | SOME ((_,f'),l') =>
            (case f'
              of Thm _ => (p::l', false)
               |  _    => (p::l', true))
in
fun add_fact (th as (s,_)) {thid, con_wrt_disk,facts,overwritten,adjoin}
  = let val (X,b) = overwrite th facts
    in {facts=X, overwritten = overwritten orelse b,
        thid=thid, con_wrt_disk=con_wrt_disk, adjoin=adjoin}
    end
end;

fun new_addon a {thid, con_wrt_disk, facts, overwritten, adjoin} =
    {adjoin = a::adjoin, facts=facts, overwritten=overwritten,
     thid=thid, con_wrt_disk=con_wrt_disk};

local fun plucky x L =
       let fun get [] A = NONE
             | get ((p as (x',_))::rst) A =
                if x=x' then SOME (rev A, p, rst) else get rst (p::A)
       in get L []
       end
in
fun set_MLbind (s1,s2) (rcd as {thid, con_wrt_disk,facts, overwritten,adjoin}) 
 = case plucky s1 facts
   of NONE => (WARN "set_MLbind" 
               (Lib.quote s1^" not found in current theory"); rcd)
    | SOME (X,(_,b),Y) =>
        {facts=X@((s2,b)::Y), overwritten=overwritten, 
         adjoin=adjoin,thid=thid, con_wrt_disk=con_wrt_disk}
end;

(*---------------------------------------------------------------------------
            Deleting from the segment
 ---------------------------------------------------------------------------*)

fun del_type (name,thyname) {thid,facts,con_wrt_disk,overwritten,adjoin} 
  = {thid=thid,facts=facts, con_wrt_disk=con_wrt_disk,adjoin=adjoin,
     overwritten = Type.TypeSig.delete (name,thyname) 
         orelse 
         (WARN "del_type" (fullname(name,thyname)^" not found");
          overwritten)}

(*---------------------------------------------------------------------------
        Remove a constant from the signature. 
 ---------------------------------------------------------------------------*)

fun del_const (name,thyname) {thid,facts,con_wrt_disk,overwritten,adjoin}
 = {thid=thid,facts=facts, con_wrt_disk=con_wrt_disk,adjoin=adjoin,
     overwritten = Term.TermSig.delete (name,thyname) orelse  
       (WARN "del_const" (fullname(name,thyname)^" not found"); overwritten)}

fun del_binding name {thid,facts,con_wrt_disk,overwritten,adjoin} =
  {facts = filter (fn (s, _) => not(s=name)) facts, 
   thid=thid, adjoin=adjoin, con_wrt_disk=con_wrt_disk, overwritten=true};

(*---------------------------------------------------------------------------
   Clean out the segment. Note: this clears out the segment, and the
   signatures, but does not alter the theory graph. The segment will 
   still be there, with its parents.
 ---------------------------------------------------------------------------*)

fun zap_segment s {thid, con_wrt_disk, facts, overwritten, adjoin} =
 let val _ = Type.TypeSig.del_segment s
     val _ = Term.TermSig.del_segment s
 in {overwritten=false, adjoin=[], facts=[], 
     con_wrt_disk=con_wrt_disk, thid=thid}
 end;

fun set_consistency b {thid, con_wrt_disk, facts, overwritten, adjoin} = 
{con_wrt_disk=b, thid=thid,facts=facts, overwritten=overwritten,adjoin=adjoin}
;
fun set_overwritten b {thid, con_wrt_disk, facts, overwritten, adjoin} = 
{overwritten=b,con_wrt_disk=con_wrt_disk, thid=thid,facts=facts, adjoin=adjoin}
;

(*---------------------------------------------------------------------------
       Wrappers for functions that alter the segment. Each time the
       segment is altered, the con_wrt_disk flag is set. This is a 
       bit stewpid and I'd like to get rid of it.
 ---------------------------------------------------------------------------*)

local fun inCT f arg = makeCT(set_consistency false (f arg (theCT())))
in
  val add_typeCT        = inCT add_type
  val add_termCT        = inCT add_term
  fun add_axiomCT(r,ax) = inCT add_fact (!r, Axiom(r,ax))
  fun add_defnCT(s,def) = inCT add_fact (s,  Defn def)
  fun add_thmCT(s,th)   = inCT add_fact (s,  Thm th)

  fun delete_type n     = inCT del_type  (n,CTname())
  fun delete_const n    = inCT del_const (n,CTname())
  val delete_binding    = inCT del_binding

  fun set_MLname s1 s2  = inCT set_MLbind (s1,s2)
  val adjoin_to_theory  = inCT new_addon
  val zapCT             = inCT zap_segment

  fun set_ct_consistency b = makeCT(set_consistency b (theCT()))
end;


(*---------------------------------------------------------------------------*
 *            INSTALLING CONSTANTS IN THE CURRENT SEGMENT                    *
 *---------------------------------------------------------------------------*)

fun new_type (Name,Arity) =
 (if Lexis.allowed_type_constant Name then ()
  else WARN "new_type" (Lib.quote Name^" is not a standard type name")
  ; add_typeCT {name=Name, arity=Arity, theory = CTname()};());

fun new_constant (Name,Ty) =
  (if Lexis.allowed_term_constant Name then ()
   else WARN "new_constant" (Lib.quote Name^" is not a standard constant name")
   ; add_termCT {name=Name, theory=CTname(), htype=Ty}; ())

(*---------------------------------------------------------------------------
     Install constants in the current theory, as part of loading a
     previously built theory from disk.
 ---------------------------------------------------------------------------*)

fun install_type(s,a,thy)   = add_typeCT {name=s, arity=a, theory=thy};
fun install_const(s,ty,thy) = add_termCT {name=s, htype=ty, theory=thy}


(*---------------------------------------------------------------------------
 * Is an object wellformed (current) wrt the symtab, i.e., have none of its
 * constants been re-declared after it was built? A constant is
 * up-to-date if either 1) it was not declared in the current theory (hence
 * it was declared in an ancestor theory and is thus frozen); or 2) it was
 * declared in the current theory and its witness is up-to-date.
 *
 * When a new entry is made in the theory, it is checked to see if it is
 * uptodate (or if its witnesses are). The "overwritten" bit of a segment
 * tells whether any element of the theory has been overwritten. If 
 * overwritten is false, then the theory is uptodate. If we want to add
 * something to an uptodate theory, then no processing need be done.
 * Otherwise, we have to examine the item, and recursively any item it
 * depends on, to see if any constant or type constant occurring in it,
 * or any theorem it depends on, is outofdate. If so, then the item 
 * will not be added to the theory.
 *
 * To clean up a theory with outofdate elements, use "scrub".
 * 
 * To tell if an object is uptodate, we can't just look at it; we have
 * to recursively examine its witness(es). We can't just accept a witness
 * that seems to be uptodate, since its constants may be flagged as uptodate,
 * but some may depend on outofdate witnesses. The solution taken
 * here is to first set all constants in the segment signature to be 
 * outofdate. Then a bottom-up pass is made. The "utd" flag in each 
 * signature entry is used to cut off repeated recursive traversal, as in
 * dynamic programming. It holds the value "true" when the witness is 
 * uptodate. 
 *---------------------------------------------------------------------------*)

local datatype constkind = TY | TM 

      fun dest_tm_entry NONE = NONE
        | dest_tm_entry (SOME{const,utd,witness}) = SOME(utd,witness)
      fun dest_ty_entry NONE = NONE
        | dest_ty_entry (SOME{const,utd,witness}) = SOME(utd,witness)

   fun init () = 
     let val thy = CTname()
     in Type.TypeSig.anachronize thy; 
        Term.TermSig.anachronize thy
     end

   fun up2date_entry CTname (utd,witness) =
     if !utd then true 
     else if up2date_witness CTname witness
          then (utd := true; true)
          else false

   and up2date_id CTname id constkind =
     if seg_of id <> CTname then true  (* not current theory *)
     else let open Type Term 
              val entryinfo = case constkind
                     of TY => dest_ty_entry(TypeSig.lookup (dest_id id))
                      | TM => dest_tm_entry(TermSig.lookup (dest_id id))
           in case entryinfo
               of NONE => false  (* entry has been deleted *)
                | SOME uw => up2date_entry CTname uw
           end

   and up2date_type CTname ty = 
     if Type.is_vartype ty then true
     else let val ((id,_),args) = Type.break_type ty
          in up2date_id CTname id TY
             andalso Lib.all (up2date_type CTname) args
          end

   and up2date_term CTname tm =
     let open Term
     in if is_const tm 
        then let val (id,ty) = break_const tm
             in up2date_id CTname id TM
                andalso up2date_type CTname ty
             end
        else case (is_var tm, is_comb tm, is_abs tm)
             of (true,_,_) => up2date_type CTname (type_of tm)
              | (_,true,_) => up2date_term CTname (rator tm) andalso 
                              up2date_term CTname (rand tm)
              | (_,_,true) => up2date_term CTname (bvar tm) andalso 
                              up2date_term CTname (body tm)
              | otherwise  => raise ERR "up2date_term" "unexpected case"
     end

   and up2date_thm CTname thm =
     Lib.all (up2date_term CTname) (Thm.concl thm::Thm.hyp thm)
       andalso
     up2date_axioms CTname (Tag.axioms_of (Thm.tag thm))

   and up2date_witness _ NONE = true
     | up2date_witness CTname (SOME(TERM tm)) = up2date_term CTname tm
     | up2date_witness CTname (SOME(THEOREM th)) = up2date_thm CTname th

   and up2date_axioms _ [] = true
     | up2date_axioms CTname rlist =
        let val axs = map (drop_Axkind o snd) (thy_axioms(theCT()))
        in Lib.all (up2date_term CTname 
                     o Thm.concl o Lib.C Lib.assoc axs) rlist
        end handle HOL_ERR _ => false
in
fun uptodate_type ty =
   if #overwritten (theCT())
   then (init(); up2date_type (CTname()) ty) else true

fun uptodate_term tm =
   if #overwritten (theCT())
   then (init (); up2date_term (CTname()) tm) else true

fun uptodate_thm thm =
   if #overwritten (theCT()) 
   then (init (); up2date_thm (CTname()) thm) else true

fun scrub_sig CT =
  let open Type Term
  in
    TypeSig.filter (fn {witness,utd,...} => up2date_entry CT (utd,witness));
    TermSig.filter (fn {witness,utd,...} => up2date_entry CT (utd,witness))
  end

fun scrub_ax CTname {thid,con_wrt_disk,facts,overwritten,adjoin} =
   let fun check (_, Thm _ ) = true
         | check (_, Defn _) = true
         | check (_, Axiom(_,th)) = up2date_term CTname (Thm.concl th)
   in
      {thid=thid, con_wrt_disk=con_wrt_disk, adjoin=adjoin,
       facts=Lib.gather check facts,overwritten=overwritten}
   end

fun scrub_thms CTname {thid,con_wrt_disk,facts,overwritten,adjoin} =
   let fun check (_, Axiom _) = true
         | check (_, Thm th ) = up2date_thm CTname th
         | check (_, Defn th) = up2date_thm CTname th
   in {thid=thid, con_wrt_disk=con_wrt_disk,adjoin=adjoin,
        facts=Lib.gather check facts, overwritten=overwritten}
   end

fun scrub () =
   let val  _  = init()
       val thy = CTname()
       val  _  = scrub_sig thy
       val {thid,con_wrt_disk,facts,overwritten,adjoin}
             = scrub_thms thy (scrub_ax thy (theCT()))
   in makeCT {overwritten=false, thid=thid,
              con_wrt_disk=con_wrt_disk, facts=facts, adjoin=adjoin}
   end
end;

fun scrubCT() = (scrub(); theCT());


(*---------------------------------------------------------------------------*
 *   WRITING AXIOMS, DEFINITIONS, AND THEOREMS INTO THE CURRENT SEGMENT      *
 *---------------------------------------------------------------------------*)

local fun check_name (fname,s) = ()
      fun DATED_ERR f bindname = ERR f (Lib.quote bindname^" is out-of-date!")
in
fun save_thm (name,th) =
      (check_name ("save_thm",name)
       ; if uptodate_thm th then add_thmCT(name,th)
         else raise DATED_ERR "save_thm" name
       ; th)

fun new_axiom (name,tm) =
   let val rname = ref name
       val axiom = Thm.mk_axiom_thm (rname,tm)
       val  _ = check_name ("new_axiom",name)
   in if uptodate_term tm then add_axiomCT(rname,axiom)
      else raise DATED_ERR "new_axiom" name
      ; axiom
   end

fun store_type_definition(name, s, witness, def) =
  let val ()  = check_name ("store_type_definition",name)
  in
    if uptodate_thm def then () 
    else raise DATED_ERR "store_type_definition" name
    ; Type.TypeSig.add_witness (s,CTname(),witness)
    ; add_defnCT(name,def)
    ; def
  end

fun store_definition (name, slist, witness, def) =
  let val ()  = check_name ("store_definition",name)
  in
    if uptodate_thm def then () else raise DATED_ERR "store_definition" name
    ; map (fn s => Term.TermSig.add_witness (s,CTname(),witness)) slist
    ; add_defnCT(name,def)
    ; def
  end
  

end;

(*---------------------------------------------------------------------------*
 * Adding a new theory into the current theory graph.                        *
 *---------------------------------------------------------------------------*)

fun set_diff a b = gather (fn x => not (Lib.op_mem thyid_eq x b)) a;
fun node_set_eq S1 S2 = null(set_diff S1 S2) andalso null(set_diff S2 S1);

fun link_parents thy plist =
 let val node = make_thyid thy
     val parents = map make_thyid plist
 in
 if Lib.all Graph.isin parents
 then if Graph.isin node
      then if node_set_eq parents (Graph.parents_of node) then ()
           else (HOL_MESG
                  "link_parents: the theory has two unequal sets of parents";
                 raise ERR "link_parents" "")
      else Graph.add (node,parents)
 else let val baddies = Lib.filter (not o Graph.isin) parents
          val names = map thyid_to_string baddies
    in HOL_MESG (String.concat
        ["link_parents: the following parents of ", 
         Lib.quote (thyid_name node), 
         "\n  should already be in the theory graph (but aren't): ", 
         String.concat (commafy names)]);
       raise ERR "link_parents" ""
    end
 end;

fun incorporate_types thy tys =
  let fun itype (s,a) = (install_type(s,a,thy);()) 
  in List.app itype tys 
  end;

fun incorporate_consts thy consts =
  let fun iconst(s,ty) = (install_const(s,ty,thy);()) 
  in List.app iconst consts 
  end;


(*---------------------------------------------------------------------------*
 *         PRINTING THEORIES OUT AS ML STRUCTURES AND SIGNATURES.            *
 *---------------------------------------------------------------------------*)

fun theory_out f {name,style} ostrm =
 let val ppstrm = Portable.mk_ppstream
                    {consumer = Portable.outputc ostrm,
                     linewidth=75, flush = fn () => Portable.flush_out ostrm}
 in f ppstrm handle e => (Portable.close_out ostrm; raise e);
    Portable.flush_ppstream ppstrm;
    Portable.close_out ostrm
 end;

fun unkind facts =
  List.foldl (fn ((s,Axiom (_,th)),(A,D,T)) => ((s,th)::A,D,T)
               | ((s,Defn th),(A,D,T))     => (A,(s,th)::D,T)
               | ((s,Thm th),(A,D,T))     => (A,D,(s,th)::T)) ([],[],[]) facts;

val utd_types  = Lib.gather uptodate_type;
val utd_consts = Lib.gather uptodate_term;
val utd_thms   = Lib.gather uptodate_thm;

(* automatically reverses the list, which is what is needed. *)

fun unadjzip [] A = A
  | unadjzip ({sig_ps,struct_ps}::t) (l1,l2) =
       unadjzip t (sig_ps::l1, struct_ps::l2)


(*---------------------------------------------------------------------------
    We always export the theory, except if it is the initial theory (named
    "scratch") and the initial theory is empty. If the initial theory is
    *not* empty, i.e., the user made some definitions, or stored some
    theorems or whatnot, then the initial theory will be exported.
 ----------------------------------------------------------------------------*)

local val mesg = Lib.with_flag(Feedback.MESG_to_string, Lib.I) HOL_MESG
in
fun export_theory () = 
 let val {thid,con_wrt_disk,facts,adjoin,overwritten} = scrubCT()
 in
 if con_wrt_disk 
 then HOL_MESG ("\nTheory "^Lib.quote(thyid_name thid)^" already \
                 \consistent with disk, hence not exported.\n")
 else 
 let val concat = String.concat
     val thyname = thyid_name thid
     val name = CTname()^"Theory"
     val (A,D,T) = unkind facts
     val (sig_ps, struct_ps) = unadjzip adjoin ([],[])
     val sigthry = {name = thyname,
                    parents = map thyid_name (Graph.fringe()),
                    axioms = A,
                    definitions = D,
                    theorems = T,
                    sig_ps = sig_ps}
     val structthry
     = {theory = dest_thyid thid,
        parents = map dest_thyid (Graph.fringe()),
        types = thy_types thyname,
        constants = Lib.mapfilter Term.dest_const (thy_constants thyname),
        axioms = A,
        definitions = D,
        theorems = T,
        struct_ps = struct_ps}
 in
   case filter (not o Lexis.ok_sml_identifier) (map fst (A@D@T))
    of [] => 
       (let val ostrm1 = Portable.open_out(concat["./",name,".sig"])
            val ostrm2 = Portable.open_out(concat["./",name,".sml"])
        in
          mesg ("Exporting theory "^Lib.quote thyname^" ... ");
          theory_out (TheoryPP.pp_sig (!pp_thm) sigthry)
                     {name=name, style="signature"} ostrm1;
          theory_out (TheoryPP.pp_struct structthry)
                     {name=name, style="structure"} ostrm2;
          set_ct_consistency true;
          mesg "done.\n"
        end
        handle e => (Lib.say "\nFailure while writing theory!\n"; raise e))

     | badnames => (HOL_MESG
          (String.concat
           ["\nThe following ML binding names in the theory to be exported:\n",
            String.concat (Lib.commafy (map Lib.quote badnames)),
            "\n are not acceptable ML identifiers.\n",
            "   Use `set_MLname <bad> <good>' to change each name."]);
          raise ERR "export_theory" "bad binding names")
 end
end end;

(*---------------------------------------------------------------------------*
 *    Allocate a new theory segment over an existing one. After              *
 *    that, initialize any registered packages. A package registers          *
 *    with a call to "after_new_theory".                                     *
 *---------------------------------------------------------------------------*)

local val initializers = ref [] : (string -> unit) list ref
in
fun after_new_theory f = (initializers := f :: !initializers)
fun initialize() =
  let val ct = current_theory()
      fun rev_app [] = ()
        | rev_app (f::rst) = 
            (rev_app rst; 
             f ct handle e =>
                let val errstr = 
                   case e 
                    of HOL_ERR r => !ERR_to_string r
                     | otherwise => General.exnMessage e
                in
                  WARN "new_theory.initialize" 
                        ("an initializer failed with message: "
                         ^errstr^"\n ... continuing anyway. \n")
                end)
  in rev_app (!initializers)
  end
end;


fun new_theory str =
  if not(Lexis.ok_identifier str)
  then raise ERR "new_theory"
         ("proposed theory name "^Lib.quote str^" is not an identifier")
  else
  let val thy as {thid, facts, con_wrt_disk,overwritten,adjoin} = theCT()
      val thyname = thyid_name thid
      fun mk_thy () = (HOL_MESG ("Created theory "^Lib.quote str);
                        makeCT(fresh_segment str); initialize())
  in
   if str=thyname
      then (HOL_MESG("Restarting theory "^Lib.quote str); 
            zapCT str; initialize())
   else
   if mem str (ancestry thyname)
      then raise ERR"new_theory" ("theory: "^Lib.quote str^" already exists.")
   else
   if thyname="scratch" andalso empty_segment thy
      then mk_thy()
   else
    (if con_wrt_disk then () else export_theory ();
     Graph.add (thid, Graph.fringe()); mk_thy ()
    )
  end;

end (* Theory *)
