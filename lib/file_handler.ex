defmodule Torrent.Filehandler do

  def start_link(tracker_info, requester_pid, output_path) do
    meta_info = tracker_info["info"]
    file_info = %{
      have: 0,
      pieces_needed: num_pieces(meta_info), 
      blocks_needed: num_blocks(meta_info),
      piece_info: meta_info["pieces"],
      requester_pid: requester_pid
    }

    { ok, pid } = Task.start_link(fn -> 
      manage_files( %{}, file_info )
    end)
    pid
  end

  defp manage_files(file_data, file_info) do
    receive do
      {:get, caller, index} ->
        send caller, file_data[index]
        manage_files(file_data, file_info)

      {:put, block, index, offset} ->
        # IO.puts "Filehandler recieved data block with index: #{index} and offset: #{offset}"
        if download_complete?(file_info) do
          write_file(file_data, file_info)
        else
          manage_files(
            file_data |> add_block(index, offset, block) |> verify_piece(index, file_info),
            file_info |> Map.update!(:have, fn i -> i + 1 end)
          )
        end
    end
  end

  def add_block(file_data, index, offset, block) do
    file_data = 
      case file_data[index] do
        nil ->
          file_data |> Map.put(index, %{})
        _ ->
          file_data
      end
    put_in(file_data, [index, offset], block)
  end

  def verify_piece(file_data, index, file_info) do
    recv_block_len = file_data[index] |> Map.keys |> length
    if recv_block_len == file_info[:blocks_needed] do
      # TODO: move this somewhere else
      data = file_data[index] 
             |> Enum.sort_by(fn({offset, block}) -> offset end)
             |> Enum.map(fn({offset, block}) -> block[:data] end)
             |> Enum.join("")

      Torrent.Parser.validate_block(file_info[:piece_info], index, data)
      send file_info[:requester_pid], { :received, index }
    end
    file_data
  end

  def write_file(file_data, count) do
    require IEx
    IEx.pry
  end

  def mkdir_tmp do
    if !File.exists?("tmp") do
      IO.puts "creating tmp file"
      File.mkdir("tmp")
    end
  end

  defp download_complete?(count) do
    # IO.puts "got #{count[:have]} from #{count[:pieces_needed]}"
    if count[:pieces_needed] == count[:have] do
      true
    else
      false
    end
  end

  def num_blocks(meta_info) do
    len = Torrent.Request.data_request_len
    meta_info["piece length"] / len |> round
  end

  def num_pieces(meta_info) do
    meta_info["length"] / meta_info["piece length"] * num_blocks(meta_info) 
    |> round
  end

  # TODO: i think this is wrong now
  def last_piece_length(meta_info) do 
    meta_info["length"] - meta_info["piece length"] * num_pieces(meta_info)
  end

end
