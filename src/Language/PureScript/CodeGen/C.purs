module Language.PureScript.CodeGen.C
  where

import Prelude

import Control.Monad.Error.Class (class MonadError, throwError)
import Control.Monad.Reader (class MonadAsk, ask, runReaderT)
import Control.Monad.State (State, execState)
import Control.Monad.State as State
import Control.MonadPlus (guard)
import CoreFn.Ann (Ann(..)) as C
import CoreFn.Binders (Binder(..)) as C
import CoreFn.Expr (Bind(..), CaseAlternative(..), Expr(..)) as C
import CoreFn.Ident (Ident(..)) as C
import CoreFn.Literal (Literal(..)) as C
import CoreFn.Meta (ConstructorType(..), Meta(..)) as C
import CoreFn.Module (Module(..)) as C
import CoreFn.Names (ModuleName(..), ProperName(..), Qualified(..)) as C
import Data.Array as A
import Data.Char as Int
import Data.Either (Either(..), either)
import Data.Identity (Identity)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Newtype (wrap, unwrap)
import Data.Traversable (for, for_, traverse)
import Data.TraversableWithIndex (traverseWithIndex)
import Data.Tuple (snd)
import Data.Tuple.Nested ((/\), type (/\))
import Language.PureScript.CodeGen.C.AST (AST)
import Language.PureScript.CodeGen.C.AST as AST
import Language.PureScript.CodeGen.C.AST as Type
import Language.PureScript.CodeGen.C.Common (freshInternalName, freshName, isInternalVariable, safeConstructorName, safeName)
import Language.PureScript.CodeGen.C.File as F
import Language.PureScript.CodeGen.C.Optimizer (optimize)
import Language.PureScript.CodeGen.C.Pretty as P
import Language.PureScript.CodeGen.C.Transforms (eraseLambdas, hoistVarDecls)
import Language.PureScript.CodeGen.Common (runModuleName)
import Language.PureScript.CodeGen.CompileError (CompileError(..))
import Language.PureScript.CodeGen.Runtime as R
import Language.PureScript.CodeGen.SupplyT (class MonadSupply, freshId)

type IsMain =
  Boolean

type Env =
  { module :: C.Module C.Ann
  }

moduleToAST
  :: ∀ m
   . MonadError CompileError m
  => MonadSupply m
  => IsMain
  -> C.Module C.Ann
  -> m (Array AST)
moduleToAST isMain mod@(C.Module { moduleName, moduleImports, moduleExports, moduleDecls, moduleForeign }) =
  let
    cModuleName =
      runModuleName moduleName
    cModulePath =
      F.cModulePath moduleName
    cIncludes =
      ("purescript" A.: _) $
       map F.cModulePath $
        (A.catMaybes [
          ado
            guard $ not (A.null moduleForeign)
            in
              C.ModuleName
                [ C.ProperName $
                    F.dottedModuleName moduleName <> "_ffi"
                ]
        ]) <> do
         A.filter
          (\(C.ModuleName pieces) ->
              case A.uncons pieces of
                Just { head: C.ProperName "Prim" } ->
                  false
                _ ->
                  true
          ) $
          A.difference <@> [ moduleName ] $
            _.moduleName <<< unwrap <$>
              moduleImports
  in runReaderT <@> { module: mod } $ do
    decls <- do
      decls <- A.concat <$> traverse (bindToAst true) moduleDecls
      eraseLambdas cModuleName =<< do
        hoistVarDecls <$>
          traverse optimize decls

    let
      moduleHeader =
        F.withHeaderGuard moduleName $
          A.concat
            [ AST.Include <<< { path: _ } <$> cIncludes
            , [ P.empty ]
            , buildConstructorDeclsWithTags mod <#>
                \{ constructorName: C.ProperName constructorName, tag } ->
                  AST.DefineTag
                    (safeConstructorName (qualifiedVarName moduleName constructorName))
                    tag
            , F.toHeader decls
            ]

      moduleBody =
        A.concat
          [ [ AST.Include { path: cModulePath } ]
          , A.concat
              [ AST.Include <<< { path: _ } <$> cIncludes
              , [ P.empty ]
              , F.toBody decls
              ]
          , [ P.empty ]
          , if isMain
              then
                [ F.nativeMain $
                    AST.Var $
                      safeName $
                        qualifiedVarName moduleName "main"
                , P.empty
                ]
              else []
          ]

    pure $
      A.concat $
        [ moduleHeader
        , [ AST.EndOfHeader ] -- TODO: return tuple instead
        , moduleBody
        ]

bindToAst
  :: ∀ m
   . MonadError CompileError m
  => MonadSupply m
  => MonadAsk Env m
  => Boolean -- ^ top-level?
  -> C.Bind C.Ann
  -> m (Array AST)
bindToAst isTopLevel (C.NonRec ann ident val) =
  A.singleton <$>
    declToAst isTopLevel (ann /\ ident) val
bindToAst isTopLevel (C.Rec vals) = ado
  asts <-
    for vals \((ann /\ ident) /\ val) ->
      declToAst isTopLevel (ann /\ ident) val

  -- convert recursive let bindings by adding one level of indirection and
  -- hiding access to the real value in a thunk which by the time it's evaluated
  -- will yield the real value.
  in if isTopLevel
    then asts
    else
      let
        asts' =
          asts <#> case _ of
            ast@AST.VariableIntroduction { name, type: typ, initialization: Just init }
             | not (isInternalVariable name) ->
              { indirInit:
                  Just $
                    AST.VariableIntroduction
                      { name: "$_indirect_" <> name
                      , type: Type.Pointer R.any
                      , qualifiers: []
                      , initialization:
                          Just $
                            AST.App R.purs_indirect_value_new []
                      }
              , ast:
                  AST.VariableIntroduction
                    { name
                    , type: R.any
                    , qualifiers: []
                    , initialization:
                        Just $
                          AST.App R.purs_indirect_thunk_new
                            [ AST.Var $ "$_indirect_" <> name ]
                    }
              , indirAssign:
                  Just $
                    AST.App R.purs_indirect_value_assign
                      [ AST.Var $ "$_indirect_" <> name
                      , init
                      ]
              }
            ast ->
              { indirInit: Nothing
              , ast
              , indirAssign: Nothing
              }

      in
        (A.catMaybes $ _.indirInit   <$> asts') <>
        (_.ast                       <$> asts') <>
        (A.catMaybes $ _.indirAssign <$> asts')

declToAst
  :: ∀ m
   . MonadError CompileError m
  => MonadSupply m
  => MonadAsk Env m
  => Boolean -- ^ is top level?
  -> (C.Ann /\ C.Ident)
  -> C.Expr C.Ann
  -> m AST
declToAst isTopLevel (x /\ ident) val = do
  { module: C.Module { moduleName } } <- ask
  name <-
    if isTopLevel
      then qualifiedVarName moduleName <$> identToVarName ident
      else identToVarName ident
  initAst <- exprToAst val
  pure $
    AST.VariableIntroduction
      { name
      , type: R.any'' [ Type.Const ]
      , qualifiers: []
      , initialization: Just initAst
      }

exprToAst
  :: ∀ m
   . MonadError CompileError m
  => MonadSupply m
  => MonadAsk Env m
  => C.Expr C.Ann
  -> m AST
exprToAst (C.Var ann (C.Qualified mModuleName ident)) =
  case mModuleName of
    Nothing ->
      AST.Var <$> identToVarName ident
    Just moduleName ->
      AST.Var <<< qualifiedVarName moduleName <$>
        identToVarName ident
exprToAst (C.Literal _ (C.NumericLiteral n)) =
  pure $
    AST.App
      (either (const R.purs_any_int_new) (const R.purs_any_num_new) n)
      [ AST.NumericLiteral n
      ]
exprToAst (C.Literal _ (C.StringLiteral s)) =
  pure $
    AST.App
      R.purs_any_string_new
      [ AST.StringLiteral s
      ]
exprToAst (C.Literal _ (C.CharLiteral c)) =
  pure $
    AST.App
      R.purs_any_char_new
      [ AST.NumericLiteral $ Left $ Int.toCharCode c
      ]
exprToAst (C.Literal _ (C.BooleanLiteral b)) =
  pure $
    if b
      then R.purs_any_true
      else R.purs_any_false
exprToAst (C.Literal _ (C.ArrayLiteral xs)) = ado
  asts <- traverse exprToAst xs
  in
    AST.App
      R.purs_any_array_new $
      [ AST.App
        R.purs_vec_new_from_array $
        [ AST.NumericLiteral $ Left $ A.length xs
        ] <>
          if A.null asts
            then [ AST.Null ]
            else asts
      ]
exprToAst (C.Literal _ (C.ObjectLiteral kvps)) = ado
  kvpAsts <-
    for kvps \(k /\ v) -> ado
      vAst <- exprToAst v
      in [ AST.StringLiteral k, vAst ]
  in
    if A.null kvps
      then
        R.purs_record_empty
      else
        AST.App
          R.purs_any_record_new $
            [ AST.App
              R.purs_record_new_from_kvps $
              [ AST.NumericLiteral $ Left $ A.length kvpAsts
              ] <> A.concat kvpAsts
            ]
exprToAst (C.Let _ binders val) = ado
  bindersAsts <- A.concat <$> traverse (bindToAst false) binders
  valAst      <- exprToAst val
  in
    AST.App R.purs_any_app
      [
        AST.Function
          { name: Nothing
          , variadic: false
          , qualifiers: []
          , arguments: []
          , returnType: R.any
          , body:
              Just $
                AST.Block $
                  bindersAsts <> [ AST.Return valAst ]
          }
      , AST.Null
      ]

exprToAst (C.Case (C.Ann { sourceSpan, type: typ }) exprs binders) = do
  assignments <- for exprs $
    exprToAst >=> \valueAst -> ado
      name <- freshName
      in
        { name
        , ast:
            AST.VariableIntroduction
              { name
              , type: R.any
              , qualifiers: []
              , initialization: Just valueAst
              }
        }

  caseAlternativeAsts :: Array (Array AST) <-
    for binders \(C.CaseAlternative { caseAlternativeBinders, caseAlternativeResult }) ->
      let
        go _ done [] =
          pure done
        go varNames done binders
          | Just { head: v, tail: vs } <- A.uncons varNames
          , Just { head: b, tail: bs } <- A.uncons binders
          = do
            done' <- go vs done bs
            binderToAst v done' b
        go _ _ _ =
          throwError $ InternalError "Invalid case alternative"
      in do
        altAsts <-
          case caseAlternativeResult of
            Left guards ->
              for guards \(guard /\ expr) -> ado
                condAst <- exprToAst guard
                valAst  <- exprToAst expr
                in
                  AST.IfElse
                    (AST.App R.purs_any_eq_int
                      [ condAst
                      , AST.NumericLiteral (Left 1)
                      ])
                    (AST.Block [ AST.Return valAst ])
                    Nothing
            Right expr ->
              A.singleton <<<
                AST.Return <$>
                  exprToAst expr

        go
          (map _.name assignments)
          altAsts
          caseAlternativeBinders

  pure $
    AST.App R.purs_any_app
      [
        AST.Function
          { name: Nothing
          , qualifiers: []
          , variadic: false
          , arguments: []
          , returnType: R.any
          , body:
              Just $
                AST.Block $ A.concat
                  [ map _.ast assignments
                  , A.concat caseAlternativeAsts
                  , [ R.purs_assert' "Failed Pattern Match" ]
                  ]
          }
      , AST.Null
      ]

  where
  binderToAst :: _ -> _ -> C.Binder C.Ann -> m (Array AST)
  binderToAst _ next (C.NullBinder _) = pure next
  binderToAst varName next (C.LiteralBinder _ lit) =
    case lit of
      C.NumericLiteral num ->
        pure
          [ AST.IfElse
              (AST.App
                (either (const R.purs_any_eq_int) (const R.purs_any_eq_num) num)
                [ AST.Var varName, AST.NumericLiteral num ])
              (AST.Block next)
              Nothing
          ]
      C.CharLiteral c ->
        pure
          [ AST.IfElse
              (AST.App
                R.purs_any_eq_char
                [ AST.Var varName, AST.CharLiteral c ])
              (AST.Block next)
              Nothing
          ]
      C.StringLiteral str ->
        pure
          [ AST.IfElse
              (AST.App
                R.purs_any_eq_string
                [ AST.Var varName, AST.StringLiteral str ])
              (AST.Block next)
              Nothing
          ]
      C.BooleanLiteral true ->
        pure
          [ AST.IfElse
              (AST.App
                R.purs_any_eq_int
                [ AST.Var varName, AST.NumericLiteral (Left 1) ])
              (AST.Block next)
              Nothing
          ]
      C.BooleanLiteral false ->
        pure
          [ AST.IfElse
              (AST.App
                R.purs_any_eq_int
                [ AST.Var varName, AST.NumericLiteral (Left 0) ])
              (AST.Block next)
              Nothing
          ]

      C.ArrayLiteral binders ->
        let
          go next' ix xs =
            case A.uncons xs of
              Nothing ->
                pure next'
              Just { head: x, tail: rest } -> do
                elementVar <- freshName
                next''     <- go next' (ix + 1) rest
                ast        <- binderToAst elementVar next'' x
                pure $
                  AST.VariableIntroduction
                    { name: elementVar
                    , type: R.any
                    , qualifiers: []
                    , initialization:
                        Just $
                          AST.Indexer
                            (AST.NumericLiteral (Left ix))
                            (AST.Accessor
                              (AST.Raw "data")
                              (AST.App R.purs_any_get_array [ AST.Var varName ]))
                    } A.: ast
        in ado
          ast <- go next 0 binders
          in
            [ AST.IfElse
                (AST.Binary
                  AST.EqualTo
                  (AST.Accessor
                    (AST.Raw "length")
                    (AST.App R.purs_any_get_array [ AST.Var varName ]))
                  (AST.NumericLiteral $ Left (A.length binders)))
                (AST.Block ast)
                Nothing
            ]

      C.ObjectLiteral binders ->
        let
          go next' xs =
            case A.uncons xs of
              Nothing ->
                pure next'
              Just { head: (prop /\ binder), tail: rest } -> do
                propVar  <- freshName
                next''   <- go next' rest
                ast      <- binderToAst propVar next'' binder
                pure $
                  AST.VariableIntroduction
                    { name: propVar
                    , type: R.any
                    , qualifiers: []
                    , initialization:
                        Just $
                          AST.Accessor
                            (AST.Raw "value")
                            (AST.App
                              R.purs_record_find_by_key
                              [
                                AST.App
                                  R.purs_any_get_record
                                  [ AST.Var varName ]
                              , AST.StringLiteral prop
                              ])
                    } A.: ast
        in
          go next binders

  binderToAst varName next (C.VarBinder _ ident) = ado
    name <- identToVarName ident
    in
      AST.VariableIntroduction
        { name
        , type: R.any
        , qualifiers: []
        , initialization: Just $ AST.Var varName
        } A.: next

  binderToAst varName next
    (C.ConstructorBinder
      (C.Ann { meta: Just C.IsNewtype }) _ _ binders)
    | Just binder <- A.head binders
    = binderToAst varName next binder

  binderToAst varName next
    (C.ConstructorBinder
      (C.Ann
        { meta: Just (C.IsConstructor constructorType fields)
        }) _ (C.Qualified mConstructorModuleName (C.ProperName constructorName)) binders) =
    let
      go xs next' =
        case A.uncons xs of
          Nothing ->
            pure next'
          Just { head: ((index /\ field) /\ binder), tail: rest } -> do
            argVarName <- freshName
            next''     <- go rest next'
            ast        <- binderToAst argVarName next'' binder
            fieldName  <- identToVarName field
            pure $
              AST.VariableIntroduction
                { name: argVarName
                , type: R.any
                , qualifiers: []
                , initialization:
                    Just $
                      AST.Indexer
                        (AST.NumericLiteral (Left index))
                        (AST.Accessor
                          (AST.Raw "values")
                          (AST.App R.purs_any_get_cons [ AST.Var varName ]))
                } A.: ast

    in
      case constructorType of
        C.ProductType ->
          go <@> next $ A.zip (A.mapWithIndex (/\) fields) binders
        C.SumType -> do
          tag <- ado
            moduleName <-
              case mConstructorModuleName of
                Just x ->
                  pure x
                Nothing -> ado
                  { module: C.Module { moduleName } } <- ask
                  in moduleName
            in safeConstructorName $ qualifiedVarName moduleName constructorName
          asts <- go <@> next $ A.zip (A.mapWithIndex (/\) fields) binders
          pure
            [
              AST.IfElse
                (AST.Binary AST.EqualTo
                  (AST.App
                    R.purs_cons_get_tag
                    [ AST.App
                        R.purs_any_get_cons
                        [ AST.Var varName
                        ]
                    ]
                  )
                  (AST.Var tag)
                )
                (AST.Block asts)
                Nothing
            ]

  binderToAst _ _ (C.ConstructorBinder _ _ _ _) =
    throwError $ InternalError $
      "binderToAst: Invalid ConstructorBinder"

  binderToAst varName next (C.NamedBinder _ ident binder) = ado
    name <- identToVarName ident
    ast <- binderToAst varName next binder
    in
      AST.VariableIntroduction
        { name
        , type: R.any
        , qualifiers: []
        , initialization: Just $ AST.Var varName
        } A.: ast

exprToAst (C.Constructor _ typeName (C.ProperName constructorName) fields)
  | Just { init: initArgs, last: lastArg } <- A.unsnoc fields
  = do
  { module: C.Module { moduleName } } <- ask

  finalLambda <- do
    argName     <- identToVarName lastArg
    valuesName  <- freshInternalName
    assignments <-
      traverseWithIndex <@> fields $ \i v -> ado
        name <- identToVarName v
        in
          AST.Assignment
            (AST.Indexer
              (AST.NumericLiteral (Left i))
              (AST.Var valuesName))
            (AST.Var name)
    pure $
     AST.Function
      { name: Nothing
      , qualifiers: []
      , variadic: false
      , arguments: [ { name: argName, type: R.any } ]
      , returnType: R.any
      , body: Just $
          AST.Block $
            [ AST.VariableIntroduction
                { name: valuesName
                , type: Type.Pointer R.any
                , qualifiers: []
                , initialization:
                    Just $
                      AST.App
                        R._PURS_CONS_VALUES_NEW
                        [ AST.NumericLiteral (Left $ A.length fields) ]
                }
            ] <> assignments <> [
              AST.Return $
                AST.App R.purs_any_cons_new
                  [ AST.Var $ safeConstructorName $ qualifiedVarName moduleName constructorName
                  , AST.Var valuesName
                  ]
            ]
      }

  A.foldM
    (\body field -> ado
        argName' <- identToVarName field
        in
          AST.Function
            { name: Nothing
            , qualifiers: []
            , variadic: false
            , arguments: [ { name: argName', type: R.any } ]
            , returnType: R.any
            , body: Just $ AST.Block [ AST.Return body ]
            }
    ) finalLambda $ A.reverse initArgs


-- note: fieldless constructors are emitted as top-level thunks that, once
-- evaluated, are stored in static storage.
exprToAst (C.Constructor _ typeName (C.ProperName constructorName) _) = do
  { module: C.Module { moduleName } } <- ask
  let
    constructorName' =
      safeConstructorName $ qualifiedVarName moduleName constructorName
  pure $
    AST.App
      R.purs_any_cons_new
      [ AST.Var constructorName'
      , AST.Null
      ]
exprToAst (C.App (C.Ann { type: typ }) ident expr) = do
  f   <- exprToAst ident
  arg <- exprToAst expr
  pure $ AST.App R.purs_any_app [f, arg]
exprToAst (C.Abs (C.Ann { type: typ }) ident expr) = do
  bodyAst <- exprToAst expr
  argName <- identToVarName ident
  pure $
    AST.Function
      { name: Nothing
      , qualifiers: []
      , variadic: false
      , arguments:
          [{ name: argName, type: R.any }]
      , returnType: R.any
      , body:
          Just $
            AST.Block
              [ AST.Return bodyAst
              ]
      }
exprToAst (C.Accessor _ k exp) = ado
  -- XXX: what if valueAst is not a record?
  valueAst <- exprToAst exp
  in
    AST.Accessor
      (AST.Raw "value")
      (AST.App
        R.purs_record_find_by_key
        [
          AST.App
            R.purs_any_get_record
            [ valueAst ]
        , AST.StringLiteral k
        ])
exprToAst (C.ObjectUpdate _ o ps) = ado
  valueAst <- exprToAst o
  sts      <- traverse (\(n /\ exp) -> (n /\ _) <$> exprToAst exp) ps
  temp     <- freshName
  in
    AST.App R.purs_any_record_new
      [ AST.App R.purs_record_add_multi $
          [ AST.App R.purs_any_get_record [ valueAst ]
          , AST.NumericLiteral (Left $ A.length sts)
          ] <> do
            A.concat $ sts <#> \(n /\ v) ->
              [ AST.StringLiteral n, v ]
      ]

qualifiedVarName :: C.ModuleName -> String -> String
qualifiedVarName (C.ModuleName pieces) varName =
  A.intercalate "_" (map unwrap pieces <> [ varName ])

identToVarName :: ∀ m. MonadError CompileError m => C.Ident -> m String
identToVarName (C.Ident name) = pure $ safeName name
identToVarName C.UnusedIdent = pure "$__unused"
identToVarName (C.GenIdent _ _) =
  throwError $
    InternalError "GenIdent in identToVarName"

type TypeName = C.ProperName
type ConstructorName = C.ProperName

buildConstructorDeclsWithTags
  :: ∀ a
   . C.Module a
  -> Array
      { typeName :: C.ProperName
      , constructorName :: C.ProperName
      , tag :: Int
      }
buildConstructorDeclsWithTags (C.Module { moduleDecls }) =
  let
    result =
      execState <@> Map.empty $
        for_ moduleDecls case _ of
          C.NonRec _ _ (C.Constructor _ typeName constructorName _) ->
            go typeName constructorName
          C.Rec xs ->
            for_ xs case _ of
              _ /\ (C.Constructor a typeName constructorName _) ->
                go typeName constructorName
              _ ->
                pure unit
          _ ->
            pure unit
  in
    A.concat $
      Map.toUnfoldable result <#> \(typeName /\ m) ->
        Map.toUnfoldable m <#> \(constructorName /\ tag) ->
          { typeName, constructorName, tag }

  where
  go
    :: C.ProperName -- ^ the type name
    -> C.ProperName -- ^ the constructor name
    -> State (Map TypeName (Map ConstructorName Int)) Unit
  go typeName constructorName = do
    m <- State.get
    case Map.lookup typeName m >>= Map.lookup constructorName of
      Just _ ->
        pure unit
      Nothing ->
        let
          m' = fromMaybe Map.empty (Map.lookup typeName m)
          ix = Map.size m'
        in
          State.put $
            Map.insert
              typeName
              (Map.insert constructorName ix m')
              m

runIdentity :: ∀ a. Identity a -> a
runIdentity = unwrap
