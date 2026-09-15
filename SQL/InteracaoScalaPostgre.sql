create SCHEMA if not EXISTS interacao_scala_postgre;

create table if not exists Interacao(
    PkInteracao serial primary key,
    NomeUsuario varchar(100) not null,
    DataInsercao timestamp without time zone default current_timestamp,
    DataAtualizacao timestamp without time zone default current_timestamp,
    Mensagem text not null,
    status integer not null check (status in (1, 2, 3))
);

create table if not EXISTS InteracaoHistorico(
    PkInteracaoHistorico serial primary key,
    FkInteracao int not null references Interacao(PkInteracao),
    DataInsercao timestamp without time zone default current_timestamp,
    DataAtualizacao timestamp without time zone default current_timestamp,
    Mensagem text not null,
    status integer not null check (status in (1, 2, 3))
);

SELECT current_database(), current_user;

SELECT table_schema, table_name
FROM information_schema.tables
WHERE LOWER(table_name) IN ('interacao', 'interacaohistorico');

BEGIN;

CREATE SCHEMA IF NOT EXISTS interacao_scala_postgre;

-- Move as tabelas existentes para o schema utilizado pelo Scala.
ALTER TABLE public.Interacao
    SET SCHEMA interacao_scala_postgre;

ALTER TABLE public.InteracaoHistorico
    SET SCHEMA interacao_scala_postgre;

-- Ajusta o nome da coluna do cadastro.
ALTER TABLE interacao_scala_postgre.Interacao
    RENAME COLUMN status TO Tier;

-- Acrescenta os campos usados pelo Scala para registrar as mudanças.
ALTER TABLE interacao_scala_postgre.InteracaoHistorico
    ADD COLUMN TierAnterior INTEGER
        CHECK (TierAnterior IN (1, 2, 3)),
    ADD COLUMN TierNovo INTEGER
        CHECK (TierNovo IN (1, 2, 3));

ALTER TABLE interacao_scala_postgre.InteracaoHistorico
    ADD CONSTRAINT historico_tiers_diferentes
        CHECK (TierAnterior <> TierNovo);

-- O Scala registra os tiers no histórico, sem enviar uma mensagem.
-- As mensagens antigas continuam armazenadas.
ALTER TABLE interacao_scala_postgre.InteracaoHistorico
    ALTER COLUMN Mensagem DROP NOT NULL;

COMMIT;

ALTER TABLE interacao_scala_postgre.InteracaoHistorico
    ALTER COLUMN status DROP NOT NULL;

SELECT PkInteracao, NomeUsuario, Tier
FROM interacao_scala_postgre.Interacao
WHERE PkInteracao = 1;

SELECT FkInteracao, TierAnterior, TierNovo
FROM interacao_scala_postgre.InteracaoHistorico
WHERE FkInteracao = 1;

SELECT PkInteracao, NomeUsuario, Tier
FROM interacao_scala_postgre.Interacao
ORDER BY PkInteracao;
