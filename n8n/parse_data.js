for (const item of $input.all()) {
  const botonesStr = item.json.botones || "";

  const botonesLista = botonesStr
    .split("|")
    .map(btn => btn.trim())
    .filter(btn => btn.length > 0);

  const botonesParseados = botonesLista.map((btn, index) => {
    return {
      tipo: "Resposta",
      texto: btn,
      id: "btn_" + index
    };
  });

  item.json.botonesParseados = botonesParseados;
}

return $input.all();