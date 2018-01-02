{-# LANGUAGE QuasiQuotes, OverloadedStrings, TemplateHaskell, RecordWildCards, ScopedTypeVariables, ExistentialQuantification, FlexibleInstances, NamedFieldPuns, MultiWayIf #-}

module Data.Aeson.TypeScript.TH (
  module Data.Aeson.TypeScript.Instances,
  module Data.Aeson.TypeScript.Types,
  module Data.Aeson.TypeScript.Formatting,
  TSDeclaration(..),
  TSField(..),
  deriveTypeScript
  ) where

import qualified Data.Aeson as A
import Data.Aeson.TypeScript.Formatting
import Data.Aeson.TypeScript.Instances ()
import Data.Aeson.TypeScript.Types
import Data.Monoid
import Data.String.Interpolate.IsString
import Data.Tagged
import qualified Data.Text as T
import Language.Haskell.TH hiding (stringE)
import Language.Haskell.TH.Datatype

-- import Debug.Trace

-- | Generates a 'TypeScript' instance declaration for the given data type or
-- data family instance constructor.
deriveTypeScript :: A.Options
                 -- ^ Encoding options.
                 -> Name
                 -- ^ Name of the type for which to generate a 'TypeScript' instance
                 -- declaration.
                 -> Q [Dec]
deriveTypeScript options name = do
  datatypeInfo@(DatatypeInfo {..}) <- reifyDatatype name

  -- traceM [i|datatype info: #{datatypeInfo}|]

  typeExpression <- getTypeExpression datatypeInfo
  let getTypeFn = FunD 'getTypeScriptType [Clause [] (NormalB typeExpression) []]

  -- If name is higher-kinded, add generic variables to the type and interface declarations
  let genericVariables :: [String] = if | length datatypeVars == 1 -> ["T"]
                                        | otherwise -> ["T" <> show i | i <- [1..(length datatypeVars)]]
  let genericVariablesExp = ListE [stringE x | x <- genericVariables]
  let genericBrackets = getGenericBrackets genericVariables

  declarationFnBody <- case A.sumEncoding options of
    A.TaggedObject tagFieldName contentsFieldName | length datatypeCons == 1 && (A.tagSingleConstructors options == False) && ((constructorVariant $ head datatypeCons) == NormalConstructor) -> do
      -- If there's a single constructor and tagSingleConstructors is False, encode to a tuple (as a single type synonym)
      let (ConstructorInfo {..}) = head datatypeCons
      let contentsTupleType = getTupleType constructorFields
      let typeDeclaration = applyToArgsE (ConE 'TSTypeAlternatives) [stringE $ getTypeName datatypeName, genericVariablesExp, ListE [getTypeAsStringExp contentsTupleType]]
      return $ NormalB $ AppE (ConE 'Tagged) (ListE [typeDeclaration])

    A.TaggedObject _ _ | A.allNullaryToStringTag options && (allConstructorsAreNullary datatypeCons) -> do
      -- Since all constructors are nullary, just encode them to strings
      let strings = [[i|"#{(A.constructorTagModifier options) $ getTypeName $ constructorName x}"|] | x <- datatypeCons]
      let typeDeclaration = AppE (AppE (AppE (ConE 'TSTypeAlternatives) (stringE $ getTypeName datatypeName)) genericVariablesExp) (ListE [stringE (s <> genericBrackets) | s <- strings])
      -- Return the single type declaration
      return $ NormalB $ AppE (ConE 'Tagged) (ListE [typeDeclaration])


    A.TaggedObject tagFieldName contentsFieldName -> do
      -- Get the type declaration
      let interfaceNames = ListE [stringE (getConstructorName (A.constructorTagModifier options) x <> genericBrackets) | x <- fmap constructorName datatypeCons]
      let typeDeclaration = applyToArgsE (ConE 'TSTypeAlternatives) [stringE $ getTypeName datatypeName, genericVariablesExp, interfaceNames]

      -- Get the interface declaration
      let interfaceDeclarations = fmap (getSumObjectConstructorDeclaration tagFieldName contentsFieldName options genericVariables) datatypeCons

      -- Return all the declarations
      return $ NormalB $ AppE (ConE 'Tagged) (ListE (typeDeclaration : interfaceDeclarations))

    A.UntaggedValue -> do
      -- Constructor names won't be encoded. Instead only the contents of the constructor will be encoded as if the type had a single constructor.
      let (ConstructorInfo {..}) = head datatypeCons
      let contentsTupleType = getTupleType constructorFields
      let typeDeclaration = applyToArgsE (ConE 'TSTypeAlternatives) [stringE $ getTypeName datatypeName, genericVariablesExp, ListE [getTypeAsStringExp contentsTupleType]]
      return $ NormalB $ AppE (ConE 'Tagged) (ListE [typeDeclaration])

    A.ObjectWithSingleField -> error [i|ObjectWithSingleField not implemented|]
    A.TwoElemArray -> error [i|TwoElemArray not implemented|]

  let getDeclarationFn = FunD 'getTypeScriptDeclaration [Clause [] declarationFnBody []]

  let nameWithTypeVariables = foldl (\x y -> AppT x y) (ConT name) datatypeVars

  return $ [InstanceD Nothing (fmap getDatatypePredicate datatypeVars) (AppT (ConT ''TypeScript) nameWithTypeVariables) [getTypeFn, getDeclarationFn]]

-- | Return an expression that evaluates to a TSInterfaceDeclaration
-- Sum object encoding to TS creates an interface for each constructor, create an interface. So
-- data Foo = Foo { fooString :: String } | Bar { barInt :: Int } becomes
-- type Foo = IFoo | IBar;
-- interface IFoo { fooString: "string" }
-- interface IBar { barInt: "number" }
getSumObjectConstructorDeclaration :: String -> String -> A.Options -> [String] -> ConstructorInfo -> Exp
getSumObjectConstructorDeclaration tagFieldName _ options genericVariables (ConstructorInfo {constructorVariant=(RecordConstructor names), ..}) = interfaceDeclaration
  where
    fieldNamesAndTypes = zip (fmap ((A.fieldLabelModifier options) . lastNameComponent') names) constructorFields
    namesAndTypes :: [(String, Type)] = case A.tagSingleConstructors options of
      True -> (tagFieldName, (ConT ''String)) : fieldNamesAndTypes
      False -> fieldNamesAndTypes
    interfaceDeclaration = assembleInterfaceDeclaration options constructorName genericVariables (getTSFields namesAndTypes)
getSumObjectConstructorDeclaration tagFieldName contentsFieldName options genericVariables (ConstructorInfo {constructorVariant=NormalConstructor, ..}) = interfaceDeclaration
  where
    contentsTupleType = getTupleType constructorFields
    namesAndTypes :: [(String, Type)] = [(tagFieldName, (ConT ''String)), (contentsFieldName, contentsTupleType)]
    interfaceDeclaration = assembleInterfaceDeclaration options constructorName genericVariables (getTSFields namesAndTypes)
getSumObjectConstructorDeclaration _tagFieldName _ _ _ (ConstructorInfo {constructorVariant=x, ..}) = error [i|Constructor variant not supported yet: #{x}|]

getUntaggedValueConstructorDeclaration :: String -> String -> A.Options -> [String] -> ConstructorInfo -> Exp
getUntaggedValueConstructorDeclaration tagFieldName _contentsFieldName options genericVariables (ConstructorInfo {constructorVariant=(RecordConstructor names), ..}) = interfaceDeclaration
  where
    namesAndTypes :: [(String, Type)] = (tagFieldName, (ConT ''String)) : (zip (fmap ((A.fieldLabelModifier options) . lastNameComponent') names) constructorFields)
    interfaceDeclaration = assembleInterfaceDeclaration options constructorName genericVariables (getTSFields namesAndTypes)

-- | Helper for getSumObjectConstructorDeclaration
getTSFields :: [(String, Type)] -> Exp
getTSFields namesAndTypes = ListE [(AppE (AppE (AppE (ConE 'TSField) (getOptionalAsBoolExp typ))
                                           (stringE nameString))
                                    (getTypeAsStringExp typ))
                                  | (nameString, typ) <- namesAndTypes]

-- | Helper for getSumObjectConstructorDeclaration
assembleInterfaceDeclaration options constructorName genericVariables members = AppE (AppE (AppE (ConE 'TSInterfaceDeclaration) constructorNameExp) genericVariablesExp) members where
  constructorNameExp = stringE $ getConstructorName (A.constructorTagModifier options) constructorName
  genericVariablesExp = (ListE [stringE x | x <- genericVariables])


-- * Getting type expression

-- | Get an expression to be used for getTypeScriptType.
-- For datatypes of kind * this is easy, since we can just evaluate the string literal in TH.
-- For higher-kinded types, we need to make an expression which evaluates the template types and fills it in.
getTypeExpression :: DatatypeInfo -> Q Exp
getTypeExpression (DatatypeInfo {datatypeVars=[], ..}) = return $ AppE (ConE 'Tagged) $ stringE $ getTypeName datatypeName
getTypeExpression (DatatypeInfo {datatypeVars=vars, ..}) = do
  let baseName = stringE $ getTypeName datatypeName
  let typeNames = ListE [getTypeAsStringExp typ | typ <- vars]
  let headType = AppE (VarE 'head) typeNames
  let tailType = AppE (VarE 'tail) typeNames
  let comma = stringE ", "
  x <- newName "x"
  let tailsWithCommas = AppE (VarE 'mconcat) (CompE [BindS (VarP x) tailType, NoBindS (AppE (AppE (VarE 'mappend) comma) (VarE x))])
  let brackets = AppE (VarE 'mconcat) (ListE [stringE "<", headType, tailsWithCommas, stringE ">"])

  return $ AppE (ConE 'Tagged) (AppE (AppE (VarE 'mappend) baseName) brackets)

-- * Util stuff

lastNameComponent :: String -> String
lastNameComponent x = T.unpack $ last $ T.splitOn "." (T.pack x)

lastNameComponent' :: Name -> String
lastNameComponent' = lastNameComponent . show

getConstructorName :: (String -> String) -> Name -> String
getConstructorName constructorTagModifier x = "I" <> (constructorTagModifier $ lastNameComponent' x)

getTypeName :: Name -> String
getTypeName x = lastNameComponent $ show x

allConstructorsAreNullary :: [ConstructorInfo] -> Bool
allConstructorsAreNullary constructors = and $ fmap isConstructorNullary constructors

isConstructorNullary :: ConstructorInfo -> Bool
isConstructorNullary (ConstructorInfo {constructorVariant, constructorFields}) = (constructorVariant == NormalConstructor) && (constructorFields == [])

getDatatypePredicate :: Type -> Pred
getDatatypePredicate typ = AppT (ConT ''TypeScript) typ

getTypeAsStringExp :: Type -> Exp
getTypeAsStringExp typ = AppE (VarE 'unTagged) (SigE (VarE 'getTypeScriptType) (AppT (AppT (ConT ''Tagged) typ) (ConT ''String)))

getOptionalAsBoolExp :: Type -> Exp
getOptionalAsBoolExp typ = AppE (VarE 'unTagged) (SigE (VarE 'getTypeScriptOptional) (AppT (AppT (ConT ''Tagged) typ) (ConT ''Bool)))

-- | Get the type of a tuple of constructor fields, as when we're packing a record-less constructor into a list
getTupleType constructorFields = case length constructorFields of
  0 -> AppT ListT (ConT ''())
  1 -> head constructorFields
  x -> applyToArgsT (ConT $ tupleTypeName x) constructorFields

-- | Helper to apply a type constructor to a list of type args
applyToArgsT :: Type -> [Type] -> Type
applyToArgsT constructor [] = constructor
applyToArgsT constructor (x:xs) = applyToArgsT (AppT constructor x) xs

-- | Helper to apply a function a list of args
applyToArgsE :: Exp -> [Exp] -> Exp
applyToArgsE f [] = f
applyToArgsE f (x:xs) = applyToArgsE (AppE f x) xs

stringE = LitE . StringL

unitSynonym :: ()
unitSynonym = ()