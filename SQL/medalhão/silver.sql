use catalog workspace;
create schema if not exists silver;

create table if not exists silver.UsuarioSnapshot(
    SkObservacao bigint generated always as identity primary key,
    CargaBronze STRING not NULL 
        references workspace.medalhao.Bronze(CargaBronze),
    IdUsuarioOrigem bigint not NULL
        check (IdUsuarioOrigem > 0),
    NomeUsuario STRING not NULL
        check (btrim(NomeUsuario) <> ''),
    tier smallint not NULL
        check (tier in (1, 2, 3)),
    
    -- Valor bruto recebido da origem, preservado para auditoria.
    RendaMensal DECIMAL(14,2)
        check (
          RendaMensal >= 0  
        ),
    -- Valor produzido pelas regras de transformação da silver.
    RendaMensalNova DECIMAL(14,2)
        check (
          RendaMensalNova >= 0
        ),
    RegraRenda STRING
        check (
          RegraRenda in (
            'AUMENTO_200_POR_CENTO',
            'REDUCAO_10_POR_CENTO',
            'SEM_ALTERACAO'
          )
        ),
    mensagem STRING,
    DataInsercaoOrigem TIMESTAMP not NULL,
    DataAtualizacaoOrigem TIMESTAMP not NULL check (DataAtualizacaoOrigem >= DataInsercaoOrigem),
    DataTratamento TIMESTAMP
);

-- Determina se o ID é primo sem converter bigint para ponto flutuante.
create or replace function workspace.silver.EhPrimo(Numero bigint)
returns boolean
language python
as $$
if Numero is None:
    return None
if Numero < 2:
    return False
if Numero == 2:
    return True
if Numero % 2 == 0:
    return False
d = 3
while d * d <= Numero:
    if Numero % d == 0:
        return False
    d += 2
return True
$$;

-- Expande os arrays JSON da bronze e aplica as regras na silver.
-- Aumento de 200% significa que a nova renda é três vezes a anterior.
merge into silver.UsuarioSnapshot as s
using (
    WITH DadosExtraidos AS (
    SELECT
        b.CargaBronze,
        j.value:pkinteracao::BIGINT AS IdUsuarioOrigem,
        j.value:nomeusuario::STRING AS NomeUsuario,
        j.value:tier::SMALLINT AS Tier,
        NULLIF(j.value:rendamensal::STRING, '')::DECIMAL(14,2) AS RendaMensal,
        j.value:mensagem::STRING AS Mensagem,
        j.value:datainsercao::TIMESTAMP AS DataInsercaoOrigem,
        j.value:dataatualizacao::TIMESTAMP AS DataAtualizacaoOrigem
    FROM workspace.medalhao.Bronze AS b,
    LATERAL variant_explode(b.DadoBruto) AS j
    ),
    DadosTransformados as (
        select
            d.*,
            case
                when d.RendaMensal is null then null
                when d.IdUsuarioOrigem % 6 = 0 then floor(d.RendaMensal * 3)
                when workspace.silver.EhPrimo(d.IdUsuarioOrigem) then floor(d.RendaMensal * 0.90)
                else d.RendaMensal
            end as RendaMensalNova,
            case
                when d.IdUsuarioOrigem % 6 = 0 then 'AUMENTO_200_POR_CENTO'
                when workspace.silver.EhPrimo(d.IdUsuarioOrigem) then 'REDUCAO_10_POR_CENTO'
                else 'SEM_ALTERACAO'
            end as RegraRenda
        from DadosExtraidos as d
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
) as d
on s.CargaBronze = d.CargaBronze and s.IdUsuarioOrigem = d.IdUsuarioOrigem
when matched then update set
    NomeUsuario = d.NomeUsuario,
    Tier = d.Tier,
    RendaMensal = d.RendaMensal,
    RendaMensalNova = d.RendaMensalNova,
    RegraRenda = d.RegraRenda,
    Mensagem = d.Mensagem,
    DataInsercaoOrigem = d.DataInsercaoOrigem,
    DataAtualizacaoOrigem = d.DataAtualizacaoOrigem,
    DataTratamento = current_timestamp
when not matched then insert (
    CargaBronze,
    IdUsuarioOrigem,
    NomeUsuario,
    Tier,
    RendaMensal,
    RendaMensalNova,
    RegraRenda,
    Mensagem,
    DataInsercaoOrigem,
    DataAtualizacaoOrigem,
    DataTratamento
) values (
    d.CargaBronze,
    d.IdUsuarioOrigem,
    d.NomeUsuario,
    d.Tier,
    d.RendaMensal,
    d.RendaMensalNova,
    d.RegraRenda,
    d.Mensagem,
    d.DataInsercaoOrigem,
    d.DataAtualizacaoOrigem,
    current_timestamp
);

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



select * from silver.UsuarioSnapshot;


SELECT
    COUNT(*) AS Total,
    COUNT(RendaMensal) AS ComRendaMensal,
    COUNT(RendaMensalNova) AS ComRendaMensalNova,
    COUNT(RegraRenda) AS ComRegraRenda
FROM silver.UsuarioSnapshot;


SELECT
    RegraRenda,
    COUNT(*) AS Quantidade,
    COUNT(RendaMensal) AS ComRendaMensal,
    COUNT(RendaMensalNova) AS ComRendaMensalNova,
    MIN(RendaMensal) AS MenorRenda,
    MAX(RendaMensal) AS MaiorRenda,
    MIN(RendaMensalNova) AS MenorRendaNova,
    MAX(RendaMensalNova) AS MaiorRendaNova
FROM silver.UsuarioSnapshot
GROUP BY RegraRenda
ORDER BY Quantidade DESC;