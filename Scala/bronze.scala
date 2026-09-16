//> using dep org.postgresql:postgresql:42.7.13

import java.sql.DriverManager
import java.nio.file.{Files, Paths}
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.UUID
import scala.util.Using

@main def FnCarregarBronze(strCaminho: String): Unit = {

  val objCaminho = Paths.get(strCaminho).toAbsolutePath.normalize()

  // Lê o arquivo uma vez para calcular o hash e obter o JSON.
  val arrBytes = Files.readAllBytes(objCaminho)

  val strHash = MessageDigest
    .getInstance("SHA-256")
    .digest(arrBytes)
    .map(b => f"${b & 0xff}%02x")
    .mkString

  // Remove somente um eventual marcador BOM no início do texto.
  val strJson = new String(arrBytes, StandardCharsets.UTF_8)
    .stripPrefix("\uFEFF")

  val objIdCarga = UUID.randomUUID()

  Using.resource(
    DriverManager.getConnection(
      sys.env("DB_URL"),
      sys.env("DB_USER"),
      sys.env("DB_PASSWORD")
    )
  ) { objConexao =>

  val strSql = """
    INSERT INTO bronze.CargaUsuario (
    CargaBronze,
    NomeArquivo,
    HashArquivo,
    DadoBruto
    )
    VALUES (?, ?, ?, CAST(? AS JSONB))

    ON CONFLICT (HashArquivo) DO NOTHING

    RETURNING
      CargaBronze AS IdCarga,
      jsonb_array_length(DadoBruto) AS QuantidadeRegistros
  """

    Using.resource(objConexao.prepareStatement(strSql)) { objComando =>
      objComando.setObject(1, objIdCarga)
      objComando.setString(2, objCaminho.getFileName.toString)
      objComando.setString(3, strHash)
      objComando.setString(4, strJson)

      Using.resource(objComando.executeQuery()) { objResultado =>
        if (objResultado.next()) {
          val intQuantidade =
            objResultado.getInt("QuantidadeRegistros")

          println(s"Carga concluída: ${objResultado.getObject("IdCarga")}")
          println(s"Registros no arquivo: $intQuantidade")
        } else {
          println("Este conteúdo já foi carregado. Nenhuma nova carga criada.")
        }
      }
    }
  }
}