defmodule Torrent.Filehandler do

  def start_link(tracker_info, requester_pid, parent, output_path) do
    meta_info = tracker_info["info"]
    file_info = %{
      pieces_needed: num_pieces(meta_info),
      blocks_in_piece: num_blocks_in_piece(meta_info),
      piece_info: meta_info["pieces"],
      requester_pid: requester_pid,
      parent_pid: parent,
      output_path: output_path,
      recv_pieces: []
    }

    { _, pid } = Task.start_link(fn -> 
      manage_files(%{}, file_info, meta_info)
    end)
    pid
  end

  defp manage_files(file_data, file_info, meta_info) do
    receive do
      {:output, pid } ->
        send pid, { :received, file_data |> Map.to_list |> length }
        manage_files(file_data, file_info, meta_info)

      {:put, block, index, offset } ->
        cond do
          index in file_info[:recv_pieces] -> # already have this
            manage_files(file_data, file_info, meta_info)

          true -> 
            { file_data, file_info } = add_block(file_data, file_info, index, offset, block)
            if download_complete?(file_info) do
              send file_info[:parent_pid], { :finished }
              write_file(file_data, file_info, meta_info)
            else
              manage_files(file_data, file_info, meta_info)
            end
        end
    end
  end

  def add_block(file_data, file_info, index, offset, block) do
    file_data = 
      case file_data[index] do
        nil ->
          file_data |> Map.put(index, %{})
        _ ->
          file_data
      end

    put_in(file_data, [index, offset], block)
    |> verify_piece(file_info, index, block[:peer])
  end

  def verify_piece(file_data, file_info, index, from) do
    recv_block_len = file_data[index] |> Map.keys |> length

    if recv_block_len == file_info[:blocks_in_piece] do
      block = concat_block(file_data[index])
      Torrent.Parser.validate_block(file_info[:piece_info], index, block)
      file_data = put_in(file_data, [index], block)
      file_info = update_in(file_info, [:recv_pieces], &(&1 ++ [index]))
      send file_info[:requester_pid], { :received, index, from }
      IO.puts "validated: #{index}"
      { file_data, file_info }
    else
      { file_data, file_info }
    end
  end

  def concat_data(file_data) do
    file_data
    |> Enum.sort_by(fn({index, _}) -> index end)
    |> Enum.map(fn({_, block}) -> block end)
    |> Enum.reduce("", fn(block, acc) -> acc <> block end)
  end

  def concat_block(block) do
    block 
    |> Enum.sort_by(fn({offset, _}) -> offset end)
    |> Enum.map(fn({_, block}) -> block[:data] end)
    |> Enum.join("")
  end

  def write_file(file_data, file_info, meta_info) do
    data = concat_data(file_data)
    if byte_size(data) != meta_info["length"] do
      require IEx
      IEx.pry
      raise "Wrong Filesize!"
    end
    mkdir_tmp()
    path = "#{file_info[:output_path]}/#{meta_info["name"]}"
    IO.puts "writing file to #{path}"
    File.write(path, data)
    IO.puts "done"
  end

  def mkdir_tmp do
    if !File.exists?("tmp") do
      # IO.puts "creating tmp file"
      File.mkdir("tmp")
    end
  end

  defp download_complete?(file_info) do
    length(file_info[:recv_pieces]) == file_info[:pieces_needed]
  end

  def num_blocks(meta_info) do
    num_pieces(meta_info) * num_blocks_in_piece(meta_info)
    |> round
  end

  def num_blocks_in_piece(meta_info) do
    meta_info["piece length"] / Torrent.Request.data_request_len
  end

  def num_pieces(meta_info) do
    num = meta_info["length"] / meta_info["piece length"]
    if trunc(num) == num do
      round(num)
    else
      round(num) + 1
    end
  end

  def last_piece_size(meta_info) do
    file_length = meta_info["length"] 
    piece_len = meta_info["piece length"] 
    num_pieces = num_pieces(meta_info) - 1
    last_piece_size = file_length - piece_len * num_pieces
  end

  def last_block_size(meta_info) do 
    data_request_len = Torrent.Request.data_request_len
    last_piece_size(meta_info) - (num_blocks_in_piece(meta_info) - 1) * data_request_len
    |> round
  end

end
