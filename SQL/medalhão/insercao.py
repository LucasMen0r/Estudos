"""Gera e insere uma carga JSON sintética na camada Bronze do Databricks.

O mesmo arquivo pode ser executado:

1. no Databricks, como arquivo/notebook Python; ou
2. no VS Code, usando a sessão configurada pelo Databricks Connect.

A Bronze recebe uma linha por carga. O campo ``DadoBruto`` contém um array JSON
com os usuários, preservando o dado original para o processamento da Silver.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional


# ---------------------------------------------------------------------------
# Configuração principal
# ---------------------------------------------------------------------------
# Estes valores podem ser alterados diretamente quando o arquivo for executado
# no Databricks. No terminal do VS Code, os argumentos de linha de comando
# substituem estes padrões.
STR_TABELA_BRONZE = "workspace.medalhao.bronze"
INT_QUANTIDADE_USUARIOS = 50
INT_SEMENTE = 20260921
INT_ID_INICIAL: Optional[int] = None
STR_SAIDA_JSON: Optional[str] = None
INT_QUANTIDADE_PREVIA = 10


@dataclass(frozen=True)
class ConfiguracaoCarga:
    """Parâmetros necessários para gerar e inserir uma carga."""

    strTabelaBronze: str = STR_TABELA_BRONZE
    intQuantidadeUsuarios: int = INT_QUANTIDADE_USUARIOS
    intSemente: int = INT_SEMENTE
    intIdInicial: Optional[int] = INT_ID_INICIAL
    strSaidaJson: Optional[str] = STR_SAIDA_JSON
    intQuantidadePrevia: int = INT_QUANTIDADE_PREVIA


COL_PRIMEIROS_NOMES = (
    "Aela",
    "Alaric",
    "Astrid",
    "Beren",
    "Brynja",
    "Cassian",
    "Cerys",
    "Dagna",
    "Draven",
    "Elara",
    "Eirik",
    "Freyja",
    "Garran",
    "Hakon",
    "Illyra",
    "Isolde",
    "Jorund",
    "Kaelen",
    "Lysandra",
    "Miraak",
    "Morwen",
    "Nerevar",
    "Ragnar",
    "Sigrid",
    "Tiber",
    "Valka",
)

COL_SOBRENOMES = (
    "Ashborn",
    "Blackbriar",
    "Crowmantle",
    "Dawnshield",
    "Dreadoath",
    "Emberheart",
    "Frostvein",
    "Grimward",
    "Ironhand",
    "Marsh-Walker",
    "Moonwhisper",
    "Nightbloom",
    "Oakenshield",
    "Ravencrest",
    "Runebinder",
    "Salt-Born",
    "Shadowmere",
    "Silver-Scale",
    "Stormcloak",
    "Thornblood",
    "Voidgazer",
    "Wolfkin",
)

COL_MENSAGENS = (
    "Cadastro criado na guilda de mercadores.",
    "Registro revisado pelo escriba imperial.",
    "Renda declarada em septims.",
    "Viajante vindo das províncias do norte.",
    "Contrato registrado sem pendências.",
    "Observação coletada para a carga mensal.",
    "Usuário ativo na data de referência.",
    "Dados recebidos da fonte de origem.",
)


def FnObterSpark() -> Any:
    """Obtém uma sessão portátil entre Databricks e Databricks Connect."""

    objSparkGlobal = globals().get("spark")
    if objSparkGlobal is not None:
        return objSparkGlobal

    try:
        from databricks.connect import DatabricksSession

        return DatabricksSession.builder.getOrCreate()
    except ImportError:
        from pyspark.sql import SparkSession

        return SparkSession.builder.getOrCreate()


def FnValidarConfiguracao(objConfiguracao: ConfiguracaoCarga) -> None:
    """Interrompe cedo quando algum parâmetro não pode gerar uma carga válida."""

    if objConfiguracao.intQuantidadeUsuarios <= 0:
        raise ValueError("intQuantidadeUsuarios deve ser maior que zero.")

    if objConfiguracao.intIdInicial is not None and objConfiguracao.intIdInicial <= 0:
        raise ValueError("intIdInicial deve ser maior que zero quando informado.")

    if objConfiguracao.intQuantidadePrevia < 0:
        raise ValueError("intQuantidadePrevia não pode ser negativa.")

    strParte = r"[A-Za-z_][A-Za-z0-9_]*"
    if re.fullmatch(rf"{strParte}(?:\.{strParte}){{0,2}}", objConfiguracao.strTabelaBronze) is None:
        raise ValueError(
            "strTabelaBronze deve usar o formato tabela, esquema.tabela ou "
            "catalogo.esquema.tabela, sem caracteres especiais."
        )


def FnNomeTabelaSql(strTabela: str) -> str:
    """Protege cada parte de um nome de tabela já validado."""

    return ".".join(f"`{strParte}`" for strParte in strTabela.split("."))


def FnContarLetras(strNome: str) -> int:
    """Conta apenas letras, ignorando espaços e hífens."""

    return sum(1 for strCaractere in strNome if strCaractere.isalpha())


def FnCalcularRenda(strNome: str, intIdUsuario: int) -> int:
    """Aplica a regra definida para a renda sintética em septims."""

    return FnContarLetras(strNome) * 15 * intIdUsuario


def FnCalcularTier(intRendaMensal: int) -> int:
    """Converte a renda nas três faixas definidas pelo exercício."""

    if intRendaMensal <= 1999:
        return 1
    if intRendaMensal <= 6999:
        return 2
    return 3


def FnGerarNome(objAleatorio: random.Random, intIdUsuario: int) -> str:
    """Gera nomes temáticos e determinísticos para uma mesma semente."""

    strPrimeiroNome = objAleatorio.choice(COL_PRIMEIROS_NOMES)
    strSobrenome = objAleatorio.choice(COL_SOBRENOMES)

    # O sufixo somente aparece se uma combinação já tiver grande chance de se
    # repetir. Ele conserva a temática sem transformar o ID no nome inteiro.
    if intIdUsuario > len(COL_PRIMEIROS_NOMES) * len(COL_SOBRENOMES):
        return f"{strPrimeiroNome} {strSobrenome} {intIdUsuario}"

    return f"{strPrimeiroNome} {strSobrenome}"


def FnFormatarDataJson(dtValor: datetime) -> str:
    """Formata um instante UTC em ISO 8601, aceito pela transformação Silver."""

    return dtValor.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def FnCriarDadosSinteticos(
    intQuantidadeUsuarios: int,
    intIdInicial: int,
    intSemente: int,
    dtReferencia: Optional[datetime] = None,
) -> list[dict[str, Any]]:
    """Cria os registros que serão serializados no array JSON da Bronze."""

    objAleatorio = random.Random(intSemente)
    dtAgora = dtReferencia or datetime.now(timezone.utc)
    colUsuarios: list[dict[str, Any]] = []

    for intDeslocamento in range(intQuantidadeUsuarios):
        intIdUsuario = intIdInicial + intDeslocamento
        strNomeUsuario = FnGerarNome(objAleatorio, intIdUsuario)
        intRendaMensal = FnCalcularRenda(strNomeUsuario, intIdUsuario)
        intTier = FnCalcularTier(intRendaMensal)

        intDiasAnteriores = objAleatorio.randint(0, 120)
        intDiasAteAtualizacao = objAleatorio.randint(0, 30)
        dtInsercao = dtAgora - timedelta(days=intDiasAnteriores)
        dtAtualizacao = min(dtInsercao + timedelta(days=intDiasAteAtualizacao), dtAgora)

        colUsuarios.append(
            {
                "pkinteracao": intIdUsuario,
                "nomeusuario": strNomeUsuario,
                "tier": intTier,
                "rendamensal": intRendaMensal,
                "mensagem": objAleatorio.choice(COL_MENSAGENS),
                "datainsercao": FnFormatarDataJson(dtInsercao),
                "dataatualizacao": FnFormatarDataJson(dtAtualizacao),
            }
        )

    return colUsuarios


def FnSerializarDados(colUsuarios: list[dict[str, Any]]) -> str:
    """Produz JSON estável para que o hash represente o conteúdo da carga."""

    return json.dumps(
        colUsuarios,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def FnObterColunasTabela(objSpark: Any, strTabelaBronze: str) -> dict[str, str]:
    """Retorna nomes físicos indexados em minúsculas."""

    if not objSpark.catalog.tableExists(strTabelaBronze):
        raise RuntimeError(
            f"A tabela {strTabelaBronze!r} não existe. Execute primeiro o SQL da Bronze."
        )

    objSchema = objSpark.table(strTabelaBronze).schema
    return {objCampo.name.lower(): objCampo.name for objCampo in objSchema.fields}


def FnValidarTabelaBronze(objSpark: Any, strTabelaBronze: str) -> dict[str, str]:
    """Confirma que a tabela importada possui o contrato esperado."""

    dicColunas = FnObterColunasTabela(objSpark, strTabelaBronze)
    colObrigatorias = {
        "cargabronze",
        "nomearquivo",
        "hasharquivo",
        "dataingestao",
        "dadobruto",
    }
    colAusentes = sorted(colObrigatorias - set(dicColunas))

    if colAusentes:
        raise RuntimeError(
            "A tabela Bronze não possui todas as colunas esperadas. "
            f"Ausentes: {', '.join(colAusentes)}. "
            f"Encontradas: {', '.join(sorted(dicColunas))}."
        )

    return dicColunas


def FnObterProximoId(objSpark: Any, strTabelaBronze: str, strColunaDadoBruto: str) -> int:
    """Localiza o maior pkinteracao já presente nos arrays JSON da Bronze."""

    from pyspark.sql import functions as F
    from pyspark.sql.types import ArrayType, LongType, StructField, StructType

    objSchemaId = ArrayType(
        StructType([StructField("pkinteracao", LongType(), True)]),
        True,
    )

    dfIds = (
        objSpark.table(strTabelaBronze)
        .select(
            F.explode_outer(
                F.from_json(F.col(strColunaDadoBruto).cast("string"), objSchemaId)
            ).alias("objUsuario")
        )
        .select(F.col("objUsuario.pkinteracao").alias("IdUsuarioOrigem"))
    )

    objResultado = dfIds.agg(F.max("IdUsuarioOrigem").alias("MaiorId")).first()
    intMaiorId = objResultado["MaiorId"] if objResultado is not None else None
    return int(intMaiorId or 0) + 1


def FnCriarDataFrameCarga(
    objSpark: Any,
    strCargaBronze: str,
    strNomeArquivo: str,
    strHashArquivo: str,
    dtDataIngestao: datetime,
    strDadoBruto: str,
) -> Any:
    """Cria uma única linha com schema explícito para evitar inferência variável."""

    from pyspark.sql.types import StringType, StructField, StructType, TimestampType

    objSchema = StructType(
        [
            StructField("CargaBronze", StringType(), False),
            StructField("NomeArquivo", StringType(), False),
            StructField("HashArquivo", StringType(), False),
            StructField("DataIngestao", TimestampType(), False),
            StructField("DadoBruto", StringType(), False),
        ]
    )

    return objSpark.createDataFrame(
        [
            (
                strCargaBronze,
                strNomeArquivo,
                strHashArquivo,
                dtDataIngestao,
                strDadoBruto,
            )
        ],
        objSchema,
    )


def FnInserirCargaBronze(
    objSpark: Any,
    dfCarga: Any,
    strTabelaBronze: str,
    dicColunas: dict[str, str],
) -> bool:
    """Insere a carga somente se o mesmo hash ainda não existir."""

    strView = f"vw_carga_bronze_{uuid.uuid4().hex}"
    dfCarga.createOrReplaceTempView(strView)

    strTabelaSql = FnNomeTabelaSql(strTabelaBronze)
    strCarga = dicColunas["cargabronze"]
    strNome = dicColunas["nomearquivo"]
    strHash = dicColunas["hasharquivo"]
    strData = dicColunas["dataingestao"]
    strDado = dicColunas["dadobruto"]

    intQuantidadeAnterior = objSpark.sql(
        f"SELECT COUNT(*) AS Quantidade "
        f"FROM {strTabelaSql} AS Alvo "
        f"INNER JOIN `{strView}` AS Fonte "
        f"ON Alvo.`{strHash}` = Fonte.`HashArquivo`"
    ).first()["Quantidade"]

    objSpark.sql(
        f"""
        MERGE INTO {strTabelaSql} AS Alvo
        USING `{strView}` AS Fonte
          ON Alvo.`{strHash}` = Fonte.`HashArquivo`
        WHEN NOT MATCHED THEN INSERT (
            `{strCarga}`,
            `{strNome}`,
            `{strHash}`,
            `{strData}`,
            `{strDado}`
        ) VALUES (
            Fonte.`CargaBronze`,
            Fonte.`NomeArquivo`,
            Fonte.`HashArquivo`,
            Fonte.`DataIngestao`,
            parse_json(Fonte.`DadoBruto`)
        )
        """
    )

    objSpark.catalog.dropTempView(strView)
    return intQuantidadeAnterior == 0


def FnSalvarJsonLocal(strDadoBruto: str, strSaidaJson: Optional[str]) -> None:
    """Opcionalmente salva uma cópia do payload para inspeção no VS Code."""

    if strSaidaJson is None:
        return

    objCaminho = Path(strSaidaJson).expanduser().resolve()
    objCaminho.parent.mkdir(parents=True, exist_ok=True)
    objCaminho.write_text(strDadoBruto, encoding="utf-8")
    print(f"Cópia JSON salva em: {objCaminho}")


def FnMostrarPrevia(objSpark: Any, colUsuarios: list[dict[str, Any]], intQuantidade: int) -> None:
    """Mostra uma amostra tabular sem coletar novamente os dados da Bronze."""

    if intQuantidade == 0:
        return

    from pyspark.sql.types import (
        LongType,
        StringType,
        StructField,
        StructType,
    )

    objSchema = StructType(
        [
            StructField("IdUsuarioOrigem", LongType(), False),
            StructField("NomeUsuario", StringType(), False),
            StructField("Tier", LongType(), False),
            StructField("RendaMensal", LongType(), False),
            StructField("Mensagem", StringType(), False),
            StructField("DataInsercaoOrigem", StringType(), False),
            StructField("DataAtualizacaoOrigem", StringType(), False),
        ]
    )

    colLinhas = [
        (
            objUsuario["pkinteracao"],
            objUsuario["nomeusuario"],
            objUsuario["tier"],
            objUsuario["rendamensal"],
            objUsuario["mensagem"],
            objUsuario["datainsercao"],
            objUsuario["dataatualizacao"],
        )
        for objUsuario in colUsuarios[:intQuantidade]
    ]

    objSpark.createDataFrame(colLinhas, objSchema).show(
        intQuantidade,
        truncate=False,
    )


def FnExecutarCarga(objConfiguracao: ConfiguracaoCarga) -> dict[str, Any]:
    """Executa o fluxo completo e devolve um resumo facilmente testável."""

    FnValidarConfiguracao(objConfiguracao)
    objSpark = FnObterSpark()
    dicColunas = FnValidarTabelaBronze(
        objSpark,
        objConfiguracao.strTabelaBronze,
    )

    intIdInicial = objConfiguracao.intIdInicial
    if intIdInicial is None:
        intIdInicial = FnObterProximoId(
            objSpark,
            objConfiguracao.strTabelaBronze,
            dicColunas["dadobruto"],
        )

    dtAgoraUtc = datetime.now(timezone.utc)
    colUsuarios = FnCriarDadosSinteticos(
        intQuantidadeUsuarios=objConfiguracao.intQuantidadeUsuarios,
        intIdInicial=intIdInicial,
        intSemente=objConfiguracao.intSemente,
        dtReferencia=dtAgoraUtc,
    )
    strDadoBruto = FnSerializarDados(colUsuarios)
    strHashArquivo = hashlib.sha256(strDadoBruto.encode("utf-8")).hexdigest()
    strCargaBronze = str(uuid.uuid5(uuid.NAMESPACE_URL, strHashArquivo))
    strNomeArquivo = f"usuarios_sinteticos_{strCargaBronze}.json"

    # Spark trabalha internamente em UTC. O objeto sem timezone evita diferenças
    # de serialização entre a execução local e a execução dentro do workspace.
    dtDataIngestao = dtAgoraUtc.replace(tzinfo=None)
    dfCarga = FnCriarDataFrameCarga(
        objSpark=objSpark,
        strCargaBronze=strCargaBronze,
        strNomeArquivo=strNomeArquivo,
        strHashArquivo=strHashArquivo,
        dtDataIngestao=dtDataIngestao,
        strDadoBruto=strDadoBruto,
    )
    boolInserida = FnInserirCargaBronze(
        objSpark=objSpark,
        dfCarga=dfCarga,
        strTabelaBronze=objConfiguracao.strTabelaBronze,
        dicColunas=dicColunas,
    )

    FnSalvarJsonLocal(strDadoBruto, objConfiguracao.strSaidaJson)
    FnMostrarPrevia(
        objSpark,
        colUsuarios,
        min(objConfiguracao.intQuantidadePrevia, len(colUsuarios)),
    )

    dicResumo = {
        "TabelaBronze": objConfiguracao.strTabelaBronze,
        "CargaBronze": strCargaBronze,
        "HashArquivo": strHashArquivo,
        "QuantidadeUsuarios": len(colUsuarios),
        "PrimeiroId": intIdInicial,
        "UltimoId": intIdInicial + len(colUsuarios) - 1,
        "Status": "INSERIDA" if boolInserida else "IGNORADA_COMO_DUPLICADA",
    }

    print(json.dumps(dicResumo, ensure_ascii=False, indent=2))
    return dicResumo


def FnLerArgumentos() -> ConfiguracaoCarga:
    """Lê argumentos no VS Code sem quebrar argumentos internos de notebooks."""

    objParser = argparse.ArgumentParser(
        description="Gera usuários sintéticos e insere uma carga JSON na Bronze."
    )
    objParser.add_argument("--tabela-bronze", default=STR_TABELA_BRONZE)
    objParser.add_argument("--quantidade", type=int, default=INT_QUANTIDADE_USUARIOS)
    objParser.add_argument("--semente", type=int, default=INT_SEMENTE)
    objParser.add_argument("--id-inicial", type=int, default=INT_ID_INICIAL)
    objParser.add_argument("--saida-json", default=STR_SAIDA_JSON)
    objParser.add_argument("--previa", type=int, default=INT_QUANTIDADE_PREVIA)
    objArgumentos, _ = objParser.parse_known_args()

    return ConfiguracaoCarga(
        strTabelaBronze=objArgumentos.tabela_bronze,
        intQuantidadeUsuarios=objArgumentos.quantidade,
        intSemente=objArgumentos.semente,
        intIdInicial=objArgumentos.id_inicial,
        strSaidaJson=objArgumentos.saida_json,
        intQuantidadePrevia=objArgumentos.previa,
    )


if __name__ == "__main__":
    FnExecutarCarga(FnLerArgumentos())
