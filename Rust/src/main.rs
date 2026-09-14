const ALIQUOTA_IRPF: f64 = 0.275;
const ALIQUOTA_RPPS: f64 = 0.14;
const TETO_CONTRIBUICAO_RPPS: f64 = 8475.55;
const ALIQUOTA_INSS: f64 = 0.11;
use std::fs;
use std::io::{self, Write};

fn renda_servidor() -> ((f64, f64), (f64, f64), f64) {
    let renda_bruta_inicial: f64 = 27676.89;
    let qtd_niveis = 10;
    let progressao_salarial: f64 = 0.07;
    let adicional_a_partir_ns4: f64 = 0.04;

    let calcular_contribuicao_rpps =
        |renda_bruta: f64| (renda_bruta * ALIQUOTA_RPPS).min(TETO_CONTRIBUICAO_RPPS);

    let calcular_renda_liquida = |renda_bruta: f64| {
        let irpf = renda_bruta * ALIQUOTA_IRPF;
        let rpps = calcular_contribuicao_rpps(renda_bruta);
        renda_bruta - irpf - rpps
    };

    let renda_liquida_inicial = calcular_renda_liquida(renda_bruta_inicial);
    let mut renda_bruta_final = renda_bruta_inicial;
    let mut renda_liquida_final = renda_liquida_inicial;
    let mut contribuicao_rpps_final = calcular_contribuicao_rpps(renda_bruta_inicial);

    for nivel in 1..=qtd_niveis {
        let progressoes = nivel - 1;
        let renda_bruta_base =
            renda_bruta_inicial * (1.0 + progressao_salarial).powi(progressoes);
        let renda_bruta = if nivel >= 4 {
            renda_bruta_base * (1.0 + adicional_a_partir_ns4)
        } else {
            renda_bruta_base
        };
        let contribuicao_rpps = calcular_contribuicao_rpps(renda_bruta);
        let renda_liquida = calcular_renda_liquida(renda_bruta);

        println!("NS{nivel}: renda bruta R$ {renda_bruta:.2} | contribuição RPPS R$ {contribuicao_rpps:.2} | renda líquida R$ {renda_liquida:.2} | IRPF R$ {:.2}",
        renda_bruta * ALIQUOTA_IRPF
        );

        renda_bruta_final = renda_bruta;
        renda_liquida_final = renda_liquida;
        contribuicao_rpps_final = contribuicao_rpps;
    }

    (
        (renda_bruta_inicial, renda_liquida_inicial),
        (renda_bruta_final, renda_liquida_final),
        contribuicao_rpps_final,
    )
}
fn frutas() {
    fn preco_fruta(fruta: &str) -> f64 {
        match fruta {
            "maca" => 2.50,
            "laranja" => 3.00,
            "banana" => 4.00,
            _ => 0.00,
        }
    }
    let macas: i32 = 10;
    let laranjas: i32 = macas + 5;

    let preco_macas = preco_fruta("maca");
    let preco_laranjas = preco_fruta("laranja");

    let valor_macas = macas as f64 * preco_macas;
    let valor_laranjas = laranjas as f64 * preco_laranjas;
    let valor_total_frutas = valor_macas + valor_laranjas;

    println!("O total de maçãs é: {macas}");
    println!("O total de laranjas é: {laranjas}");
    println!("O total de frutas é: {}", macas + laranjas);

    println!("O valor das maçãs é: R$ {valor_macas:.2}");
    println!("O valor das laranjas é: R$ {valor_laranjas:.2}");
    println!("O valor total das frutas é: R$ {valor_total_frutas:.2}");
}
fn renda_clt() -> (f64, f64) {
    let renda_bruta_clt: f64 = 7000.00;
    let vale_transporte = renda_bruta_clt * 0.06;
    let inss = renda_bruta_clt * ALIQUOTA_INSS;

    let renda_liquida_clt =
        renda_bruta_clt - vale_transporte - inss;

    println!("Renda líquida CLT: R$ {renda_liquida_clt:.2}");

    (renda_bruta_clt, renda_liquida_clt)
}
fn renda_clt_servidor(
    renda_bruta_servidor: f64,
    renda_liquida_servidor: f64,
    renda_bruta_clt: f64,
    renda_liquida_clt: f64,
) {
    let diferenca_bruta =
        ((renda_bruta_servidor - renda_bruta_clt)
            / renda_bruta_clt)
            * 100.0;

    let diferenca_liquida =
        ((renda_liquida_servidor - renda_liquida_clt)
            / renda_liquida_clt)
            * 100.0;

    println!(
        "Diferença entre as rendas brutas: {diferenca_bruta:.2}%"
    );

    println!(
        "Diferença entre as rendas líquidas: {diferenca_liquida:.2}%"
    );
}
fn qtd_servidores() -> i64 {
    let qtd_servidores: i64 = 217;
    let qtd_servidores_ativos: i64 = 49;
    let qtd_servidores_inativos: i64 = qtd_servidores - qtd_servidores_ativos;

    let porcentagem_inativos =
        qtd_servidores_inativos as f64
        / qtd_servidores as f64
        * 100.0;

    println!(
        "A porcentagem de cargos vagos é de: {porcentagem_inativos:.2}%"
    );

    qtd_servidores_inativos
}

fn baixar_planilha_rfb() {
    const URL_PLANILHA: &str = 
        "https://www.gov.br/receitafederal/pt-br/acesso-a-informacao/\
            dados-abertos/receitadata/arrecadacao/serie-historica/\
            arrecadacao-das-receitas-federais-1994-a-2025.xlsx/@@download/file";
    const URL_PLANILHA_ANOS_70_ATE_1993: &str = "https://www.gov.br/receitafederal/pt-br/acesso-a-informacao/dados-abertos/receitadata/arrecadacao/serie-historica/arrecadacao-das-receitas-federais-1970-a-1993.xlsx/@@download/file";

    const ARQUIVO_SAIDA: &str = "arrecadacao_1994_2025.xlsx";
    const ARQUIVO_SAIDA_ANTIGA: &str = "arrecadacao_1970_1993.xlsx";

    let cliente = reqwest::blocking::Client::builder()
        .user_agent("crawler-rust-estudo/0.1")
        .build()
        .expect("Não foi possível criar o cliente HTTP");

    let resposta = cliente
        .get(URL_PLANILHA)
        .send()
        .expect("Não foi possível acessar a Receita Federal");

    println!("Status da requisição: {}", resposta.status());

    let resposta = resposta
        .error_for_status()
        .expect("A Receita Federal retornou um erro HTTP");

    let conteudo = resposta
        .bytes()
        .expect("Não foi possível ler a planilha recebida");

    fs::write(ARQUIVO_SAIDA, conteudo.as_ref())
        .expect("Não foi possível salvar a planilha");

    println!(
        "Planilha salva em {ARQUIVO_SAIDA} — {} bytes recebidos",
        conteudo.len()
    );
}

fn ler_ano(mensagem: &str) -> i32 {
    loop {
        let mut entrada = String::new();

        print!("{mensagem}");
        io::stdout()
            .flush()
            .expect("Não foi possível exibir a mensagem");

        io::stdin()
            .read_line(&mut entrada)
            .expect("Não foi possível ler o ano");

        match entrada.trim().parse::<i32>() {
            Ok(ano) if (1994..=2025).contains(&ano) => {
                return ano;
            }
            Ok(_) => {
                println!("Escolha um ano entre 1994 e 2025.");
            }
            Err(_) => {
                println!("Digite apenas o ano, como 2015.");
            }
        }
    }
}

fn comparar_anos(
    ano_base: i32,
    arrecadacao_base: f64,
    ano_comparado: i32,
    arrecadacao_comparada: f64,
) {
    let diferenca = arrecadacao_comparada - arrecadacao_base;

    let variacao_percentual =
        diferenca / arrecadacao_base * 100.0;

    println!("\nComparação entre {ano_base} e {ano_comparado}:");
    println!(
        "{ano_base}: R$ {arrecadacao_base:.2}"
    );
    println!(
        "{ano_comparado}: R$ {arrecadacao_comparada:.2}"
    );
    println!(
        "Diferença: R$ {diferenca:.2}"
    );
    println!(
        "Variação: {variacao_percentual:.2}%"
    );

    if diferenca > 0.0 {
        println!("A arrecadação aumentou.");
    } else if diferenca < 0.0 {
        println!("A arrecadação diminuiu.");
    } else {
        println!("Os valores são iguais.");
    }
}

fn main() {

    baixar_planilha_rfb();
    comparar_anos(ano_base, arrecadacao_base, ano_comparado, arrecadacao_comparada);
    fn main() {
    let ano_base = ler_ano("Digite o ano-base: ");

    let ano_comparado = loop {
        let ano = ler_ano("Digite o ano que deseja comparar: ");

        if ano != ano_base {
            break ano;
        }

        println!("Escolha dois anos diferentes.");
    };

    baixar_planilha_rfb();

    // Valores provisórios para testar a comparação
    let arrecadacao_base = 1_800_000_000_000.00;
    let arrecadacao_comparada = 2_100_000_000_000.00;

    comparar_anos(
        ano_base,
        arrecadacao_base,
        ano_comparado,
        arrecadacao_comparada,
    );

    qtd_servidores();

    let (
        (renda_bruta_inicial, renda_liquida_inicial),
        (renda_bruta_final, renda_liquida_final),
        contribuicao_rpps_final,
    ) = renda_servidor();

    println!("Contribuição RPPS no último nível: R$ {contribuicao_rpps_final:.2}");

    frutas();

    let (renda_bruta_clt, renda_liquida_clt) = renda_clt();

    println!("\nComparação com o início da carreira:");

    renda_clt_servidor(
        renda_bruta_inicial,
        renda_liquida_inicial,
        renda_bruta_clt,
        renda_liquida_clt,
    );

    println!("\nComparação com o final da carreira:");

    renda_clt_servidor(
        renda_bruta_final,
        renda_liquida_final,
        renda_bruta_clt,
        renda_liquida_clt,
    );
    }
}