create schema if not exists silver;

create table if not exists silver.UsuarioSnapshot(
    SkObservacao integer generated always as identity primary key,
    CargaBronze UUID not NULL 
        references bronze.CargaUsuario(CargaBronze),
    IdUsuarioOrigem bigint not NULL
        check (IdUsuarioOrigem > 0),
    NomeUsuario text not NULL
        check (btrim(NomeUsuario) <> ''),
    tier smallint not NULL
        check (tier in (1, 2, 3)),
    
    -- Valor bruto recebido da origem, preservado para auditoria.
    RendaMensal numeric (14,2)
        check (
          RendaMensal >= 0 and RendaMensal < 'infinity'::numeric  
        ),
    -- Valor produzido pelas regras de transformação da silver.
    RendaMensalNova numeric (14,2)
        check (
          RendaMensalNova >= 0 and RendaMensalNova < 'infinity'::numeric
        ),
    RegraRenda text
        check (
          RegraRenda in (
            'AUMENTO_200_POR_CENTO',
            'REDUCAO_10_POR_CENTO',
            'SEM_ALTERACAO'
          )
        ),
    mensagem text,
    DataInsercaoOrigem timestamp without time zone not NULL,
    DataAtualizacaoOrigem timestamp without time zone not NULL,
    DataTratamento timestamp without time zone default current_timestamp,

    constraint UsuarioSnapshotDataValida
        check (DataAtualizacaoOrigem >= DataInsercaoOrigem),

    constraint UsuarioSnapshotCargaUsuarioUnico
        unique(CargaBronze, IdUsuarioOrigem)
);

-- Compatibilidade com tabelas criadas antes das novas regras de renda.
alter table silver.UsuarioSnapshot
    add column if not exists RendaMensalNova numeric(14,2)
        check (
          RendaMensalNova >= 0 and RendaMensalNova < 'infinity'::numeric
        );

alter table silver.UsuarioSnapshot
    add column if not exists RegraRenda text
        check (
          RegraRenda in (
            'AUMENTO_200_POR_CENTO',
            'REDUCAO_10_POR_CENTO',
            'SEM_ALTERACAO'
          )
        );

-- Determina se o ID é primo sem converter bigint para ponto flutuante.
create or replace function silver.EhPrimo(Numero bigint)
returns boolean
language plpgsql
immutable
strict
parallel safe
as $$
declare
    Divisor bigint := 3;
begin
    if Numero < 2 then
        return false;
    elsif Numero = 2 then
        return true;
    elsif Numero % 2 = 0 then
        return false;
    end if;

    while Divisor <= Numero / Divisor loop
        if Numero % Divisor = 0 then
            return false;
        end if;
        Divisor := Divisor + 2;
    end loop;

    return true;
end;
$$;

-- Expande os arrays JSON da bronze e aplica as regras na silver.
-- Aumento de 200% significa que a nova renda é três vezes a anterior.
with DadosExtraidos as (
    select
        b.CargaBronze,
        (j.Item ->> 'pkinteracao')::bigint as IdUsuarioOrigem,
        j.Item ->> 'nomeusuario' as NomeUsuario,
        (j.Item ->> 'tier')::smallint as Tier,
        nullif(j.Item ->> 'rendamensal', '')::numeric(14,2) as RendaMensal,
        j.Item ->> 'mensagem' as Mensagem,
        (j.Item ->> 'datainsercao')::timestamp as DataInsercaoOrigem,
        (j.Item ->> 'dataatualizacao')::timestamp as DataAtualizacaoOrigem
    from bronze.CargaUsuario as b
    cross join lateral jsonb_array_elements(b.DadoBruto) as j(Item)
),
DadosTransformados as (
    select
        d.*,
        case
            when d.RendaMensal is null then null
            when d.IdUsuarioOrigem % 6 = 0 then floor(d.RendaMensal * 3)
            when silver.EhPrimo(d.IdUsuarioOrigem) then floor(d.RendaMensal * 0.90)
            else d.RendaMensal
        end as RendaMensalNova,
        case
            when d.IdUsuarioOrigem % 6 = 0 then 'AUMENTO_200_POR_CENTO'
            when silver.EhPrimo(d.IdUsuarioOrigem) then 'REDUCAO_10_POR_CENTO'
            else 'SEM_ALTERACAO'
        end as RegraRenda
    from DadosExtraidos as d
)
insert into silver.UsuarioSnapshot as s (
    CargaBronze,
    IdUsuarioOrigem,
    NomeUsuario,
    Tier,
    RendaMensal,
    RendaMensalNova,
    RegraRenda,
    Mensagem,
    DataInsercaoOrigem,
    DataAtualizacaoOrigem
)
select
    CargaBronze,
    IdUsuarioOrigem,
    NomeUsuario,
    Tier,
    RendaMensal,
    RendaMensalNova,
    RegraRenda,
    Mensagem,
    DataInsercaoOrigem,
    DataAtualizacaoOrigem
from DadosTransformados
on conflict (CargaBronze, IdUsuarioOrigem)
do update set
    NomeUsuario = excluded.NomeUsuario,
    Tier = excluded.Tier,
    RendaMensal = excluded.RendaMensal,
    RendaMensalNova = excluded.RendaMensalNova,
    RegraRenda = excluded.RegraRenda,
    Mensagem = excluded.Mensagem,
    DataInsercaoOrigem = excluded.DataInsercaoOrigem,
    DataAtualizacaoOrigem = excluded.DataAtualizacaoOrigem,
    DataTratamento = current_timestamp;

select
    CargaBronze,
    IdUsuarioOrigem,
    NomeUsuario,
    RendaMensal as RendaAnterior,
    RendaMensalNova as RendaNova,
    RendaMensalNova - RendaMensal as DiferencaRenda,
    RegraRenda
from silver.UsuarioSnapshot
order by CargaBronze, IdUsuarioOrigem;
