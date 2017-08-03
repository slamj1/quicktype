module Elm 
    ( renderer
    ) where

import Doc
import IRGraph
import Prelude

import Data.Array as A
import Data.Char.Unicode (isLetter)
import Data.Foldable (for_, intercalate)
import Data.List (List, (:))
import Data.List as L
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe)
import Data.Set (Set)
import Data.Set as S
import Data.String as Str
import Data.String.Util (capitalize, decapitalize, camelCase, stringEscape)
import Data.Tuple (Tuple(..), fst)
import Utils (forEnumerated_, removeElement, sortByKey, sortByKeyM)

forbiddenWords :: Array String
forbiddenWords =
    [ "if", "then", "else"
    , "case", "of"
    , "let", "in"
    , "type"
    , "module", "where"
    , "import", "exposing"
    , "as"
    , "port"
    , "int", "float", "bool", "string"
    , "jenc", "jdec", "jpipe"
    , "always", "identity"
    , "array", "dict", "maybe"
    ]

forbiddenPropertyNames :: Set String
forbiddenPropertyNames = S.fromFoldable forbiddenWords

forbiddenNames :: Array String
forbiddenNames = map capitalize forbiddenWords

renderer :: Renderer
renderer =
    { name: "Elm"
    , aceMode: "elm"
    , extension: "elm"
    , doc: elmDoc
    , transforms:
        { nameForClass
        , unionName: Just unionName
        , unionPredicate: Just unionPredicate
        , nextName: \s -> "Other" <> s
        , forbiddenNames: forbiddenNames
        , topLevelNameFromGiven: const "Root"
        , forbiddenFromTopLevelNameGiven: upperNameStyle >>> A.singleton
        }
    }

nameForClass :: IRClassData -> String
nameForClass (IRClassData { names }) = upperNameStyle $ combineNames names

unionName :: L.List String -> String
unionName s =
    L.sort s
    <#> upperNameStyle
    # intercalate "Or"

unionPredicate :: IRType -> Maybe (Set IRType)
unionPredicate = case _ of
    IRUnion ur ->
        let s = unionToSet ur
        in case nullableFromSet s of
            Nothing -> Just s
            _ -> Nothing
    _ -> Nothing

isLetterCharacter :: Char -> Boolean
isLetterCharacter c =
    isLetter c || c == '_'

legalizeIdentifier :: Boolean -> String -> String
legalizeIdentifier upper str =
    case Str.charAt 0 str of
    Nothing -> "Empty"
    Just s ->
        if isLetter s then
            Str.fromCharArray $ map (\c -> if isLetterCharacter c then c else '_') $ Str.toCharArray str
        else
            legalizeIdentifier upper ((if upper then "F_" else "f_") <> str)

lowerNameStyle :: String -> String
lowerNameStyle = camelCase >>> decapitalize >>> (legalizeIdentifier false)

upperNameStyle :: String -> String
upperNameStyle = camelCase >>> capitalize >>> (legalizeIdentifier true)

renderComment :: Maybe String -> String
renderComment (Just s) = " -- " <> s
renderComment Nothing = ""

elmDoc :: Doc Unit
elmDoc = do
    givenTopLevel <- upperNameStyle <$> getTopLevelNameGiven
    topLevelDecoder <- lowerNameStyle <$> getTopLevelNameGiven
    line """-- To decode the JSON data, add this file to your project, run
--
--     elm-package install NoRedInk/elm-decode-pipeline
--
-- add these imports
--
--    import Json.Decode exposing (decodeString)"""
    line $ "--    import " <> givenTopLevel <> " exposing (" <> topLevelDecoder <> ")"
    line """--
-- and you're off to the races with
--"""
    line $ "--     decodeString " <> topLevelDecoder <> " myJsonString"
    blank
    line $ "module " <> givenTopLevel <> " exposing (" <> givenTopLevel <> ", " <> topLevelDecoder <> ", encode" <> givenTopLevel <> ")"
    blank
    line """import Json.Decode as Jdec
import Json.Decode.Pipeline as Jpipe
import Json.Encode as Jenc
import Array
import Dict

-- top level type
"""
    topLevel <- getTopLevel
    { rendered: topLevelRendered } <- typeStringForType topLevel
    line $ "type alias " <> givenTopLevel <> " = " <> topLevelRendered
    blank
    { rendered: rootDecoder } <- decoderNameForType topLevel
    line $ topLevelDecoder <> " : Jdec.Decoder " <> givenTopLevel
    line $ topLevelDecoder <> " = " <> rootDecoder
    blank
    { rendered: rootEncoder } <- encoderNameForType topLevel
    line $ "encode" <> givenTopLevel <> " : " <> givenTopLevel <> " -> String"
    line $ "encode" <> givenTopLevel <> " r = Jenc.encode 0 (" <> rootEncoder <> " r)"
    blank
    line "-- JSON types"
    classes <- getClasses
    unions <- getUnions
    for_ classes \(Tuple i cls) -> do
        blank
        typeRenderer renderTypeDefinition i cls
    for_ unions \types -> do
        blank
        renderUnionDefinition types
    blank
    line "-- decoders and encoders"
    for_ classes \(Tuple i cls) -> do
        blank
        typeRenderer renderTypeFunctions i cls
    for_ unions \types -> do
        blank
        renderUnionFunctions types
    blank
    line """--- encoder helpers

array__enc : (a -> Jenc.Value) -> Array.Array a -> Jenc.Value
array__enc f arr =
    Jenc.array (Array.map f arr)

dict__enc : (a -> Jenc.Value) -> Dict.Dict String a -> Jenc.Value
dict__enc f dict =
    Jenc.object (Dict.toList (Dict.map (\k -> f) dict))

nullable__enc : (a -> Jenc.Value) -> Maybe a -> Jenc.Value
nullable__enc f m =
    case m of
    Just x -> f x
    Nothing -> Jenc.null"""

singleWord :: String -> Doc { rendered :: String, multiWord :: Boolean }
singleWord w = pure { rendered: w, multiWord: false }

multiWord :: String -> String -> Doc { rendered :: String, multiWord :: Boolean }
multiWord s1 s2 = pure { rendered: s1 <> " " <> s2, multiWord: true }

parenIfNeeded :: { rendered :: String, multiWord :: Boolean } -> String
parenIfNeeded { rendered, multiWord: false } = rendered
parenIfNeeded { rendered, multiWord: true } = "(" <> rendered <> ")"

typeStringForType :: IRType -> Doc { rendered :: String, multiWord :: Boolean }
typeStringForType = case _ of
    IRNothing -> singleWord "Jdec.Value"
    IRNull -> singleWord "()"
    IRInteger -> singleWord "Int"
    IRDouble -> singleWord "Float"
    IRBool -> singleWord "Bool"
    IRString -> singleWord "String"
    IRArray a -> do
        ts <- typeStringForType a
        multiWord "Array.Array" $ parenIfNeeded ts
    IRClass i -> singleWord =<< lookupClassName i
    IRMap t -> do
        ts <- typeStringForType t
        multiWord "Dict.Dict String" $ parenIfNeeded ts
    IRUnion u ->
        let s = unionToSet u
        in case nullableFromSet s of
        Just x -> do
            ts <- typeStringForType x
            multiWord "Maybe" $ parenIfNeeded ts
        Nothing -> do
            singleWord =<< lookupUnionName s

lookupClassDecoderName :: Int -> Doc String
lookupClassDecoderName i = decapitalize <$> lookupClassName i

lookupUnionDecoderName :: Set IRType -> Doc String
lookupUnionDecoderName s = decapitalize <$> lookupUnionName s

encoderNameFromDecoderName :: String -> String
encoderNameFromDecoderName decoderName = "enc__" <> decoderName

unionConstructorName :: Set IRType -> IRType -> Doc String
unionConstructorName s t = do
    typeName <- upperNameStyle <$> getTypeNameForUnion t
    unionName <- lookupUnionName s
    pure $ typeName <> "In" <> unionName

decoderNameForType :: IRType -> Doc { rendered :: String, multiWord :: Boolean }
decoderNameForType = case _ of
    IRNothing -> singleWord "Jdec.value"
    IRNull -> multiWord "Jdec.null" "()"
    IRInteger -> singleWord "Jdec.int"
    IRDouble -> singleWord "Jdec.float"
    IRBool -> singleWord "Jdec.bool"
    IRString -> singleWord "Jdec.string"
    IRArray a -> do
        dn <- decoderNameForType a
        multiWord "Jdec.array" $ parenIfNeeded dn
    IRClass i -> singleWord =<< lookupClassDecoderName i
    IRMap t -> do
        dn <- decoderNameForType t
        multiWord "Jdec.dict" $ parenIfNeeded dn
    IRUnion u ->
        let s = unionToSet u
        in case nullableFromSet s of
        Just t -> do
            dn <- decoderNameForType t
            multiWord "Jdec.nullable" $ parenIfNeeded dn
        Nothing -> do
            singleWord =<< lookupUnionDecoderName s

encoderNameForType :: IRType -> Doc { rendered :: String, multiWord :: Boolean }
encoderNameForType = case _ of
    IRNothing -> singleWord "identity"
    IRNull -> multiWord "always" "Jenc.null"
    IRInteger -> singleWord "Jenc.int"
    IRDouble -> singleWord "Jenc.float"
    IRBool -> singleWord "Jenc.bool"
    IRString -> singleWord "Jenc.string"
    IRArray a -> do
        rendered <- encoderNameForType a
        multiWord "array__enc" $ parenIfNeeded rendered
    IRClass i -> singleWord =<< encoderNameFromDecoderName <$> lookupClassDecoderName i
    IRMap t -> do
        rendered <- encoderNameForType t
        multiWord "dict__enc" $ parenIfNeeded rendered
    IRUnion u ->
        let s = unionToSet u
        in case nullableFromSet s of
        Just t -> do
            rendered <- encoderNameForType t
            multiWord "nullable__enc" $ parenIfNeeded rendered
        Nothing ->
            singleWord =<< encoderNameFromDecoderName <$> lookupUnionDecoderName s

forWithPrefix_ :: forall a b p m. Applicative m => List a -> p -> p -> (p -> a -> m b) -> m Unit
forWithPrefix_ l firstPrefix restPrefix f =
    forEnumerated_ l (\i -> f $ if i == 0 then firstPrefix else restPrefix)

isOptional :: IRType -> Boolean
isOptional = case _ of
    IRUnion u ->
        case nullableFromSet $ unionToSet u of
        Just t -> true
        Nothing -> false
    -- IRNull -> true
    -- IRUnion u -> S.member IRNull $ unionToSet u
    _ -> false

renderTypeDefinition :: Int -> String -> Map.Map String String -> List (Tuple String IRType) -> Doc Unit
renderTypeDefinition classIndex className propertyNames propsList = do
    line $ "type alias " <> className <> " ="
    indent do
        forWithPrefix_ propsList "{ " ", " \braceOrComma (Tuple pname ptype) -> do
            let propName = lookupName pname propertyNames
            { rendered } <- typeStringForType ptype
            line $ braceOrComma <> propName <> " : " <> rendered
        when (propsList == L.Nil) do
            line "{"
        line "}"

renderTypeFunctions :: Int -> String -> Map.Map String String -> List (Tuple String IRType) -> Doc Unit
renderTypeFunctions classIndex className propertyNames propsList = do
    decoderName <- lookupClassDecoderName classIndex
    line $ decoderName <> " : Jdec.Decoder " <> className
    line $ decoderName <> " ="
    indent do
        line $ "Jpipe.decode " <> className
        for_ propsList \(Tuple pname ptype) -> do
            indent do
                propDecoder <- decoderNameForType ptype
                let { reqOrOpt, fallback } = if isOptional ptype then { reqOrOpt: "Jpipe.optional", fallback: " Nothing" } else { reqOrOpt: "Jpipe.required", fallback: "" }
                line $ "|> " <> reqOrOpt <> " \"" <> stringEscape pname <> "\" " <> (parenIfNeeded propDecoder) <> fallback
    blank
    let encoderName = encoderNameFromDecoderName decoderName
    line $ encoderName <> " : " <> className <> " -> Jenc.Value"
    line $ encoderName <> " x ="
    indent do
        line "Jenc.object"
        indent do
            forWithPrefix_ propsList "[ " ", " \bracketOrComma (Tuple pname ptype) -> do
                let propName = lookupName pname propertyNames
                { rendered: propEncoder } <- encoderNameForType ptype
                line $ bracketOrComma <> "(\"" <> stringEscape pname <> "\", " <> propEncoder <> " x." <> propName <> ")"
        when (propsList == L.Nil) do
            line "["
        line "]"

typeRenderer :: (Int -> String -> Map.Map String String -> List (Tuple String IRType) -> Doc Unit) -> Int -> IRClassData -> Doc Unit
typeRenderer renderer classIndex (IRClassData { properties }) = do
    className <- lookupClassName classIndex
    let propertyNames = transformNames lowerNameStyle (\n -> "other" <> capitalize n) forbiddenPropertyNames $ map (\n -> Tuple n n) $ Map.keys properties
    let propsList = Map.toUnfoldable properties # sortByKey (\t -> lookupName (fst t) propertyNames)
    renderer classIndex className propertyNames propsList

renderUnionDefinition :: Set IRType -> Doc Unit
renderUnionDefinition allTypes = do
    unionName <- lookupUnionName allTypes
    fields <- L.fromFoldable allTypes # sortByKeyM (unionConstructorName allTypes)
    line $ "type " <> unionName
    forWithPrefix_ fields "=" "|" \equalsOrPipe t -> do
        indent do
            constructor <- unionConstructorName allTypes t
            when (t == IRNull) do
                line $ equalsOrPipe <> " " <> constructor
            unless (t == IRNull) do
                ts <- typeStringForType t
                line $ equalsOrPipe <> " " <> constructor <> " " <> (parenIfNeeded ts)

renderUnionFunctions :: Set IRType -> Doc Unit
renderUnionFunctions allTypes = do
    unionName <- lookupUnionName allTypes
    decoderName <- lookupUnionDecoderName allTypes
    line $ decoderName <> " : Jdec.Decoder " <> unionName
    line $ decoderName <> " ="
    indent do
        let { element: maybeArray, rest: nonArrayFields } = removeElement isArray allTypes
        nonArrayDecFields <- L.fromFoldable nonArrayFields # sortByKeyM (unionConstructorName allTypes)
        let decFields = maybe nonArrayDecFields (\f -> f : nonArrayDecFields) maybeArray
        line "Jdec.oneOf"
        indent do
            forWithPrefix_ decFields "[" "," \bracketOrComma t -> do
                constructor <- unionConstructorName allTypes t
                when (t == IRNull) do
                    line $ bracketOrComma <> " Jdec.null " <> constructor
                unless (t == IRNull) do
                    decoder <- decoderNameForType t
                    line $ bracketOrComma <> " Jdec.map " <> constructor <> " " <> parenIfNeeded decoder
            line "]"
    blank
    let encoderName = encoderNameFromDecoderName decoderName
    line $ encoderName <> " : " <> unionName <> " -> Jenc.Value"
    line $ encoderName <> " x = case x of"
    indent do
        fields <- L.fromFoldable allTypes # sortByKeyM (unionConstructorName allTypes)
        for_ fields \t -> do
            constructor <- unionConstructorName allTypes t
            when (t == IRNull) do
                line $ constructor <> " -> Jenc.null"
            unless (t == IRNull) do
                { rendered: encoder } <- encoderNameForType t
                line $ constructor <> " y -> " <> encoder <> " y"
