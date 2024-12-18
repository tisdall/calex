defmodule Calex.Decoder do
  @moduledoc false

  alias Calex.{DecodeError, InvalidTimeZoneError}

  # https://rubular.com/r/sXPKG84KfgtfMV
  @utc_datetime_pattern ~r/^\d{8}T\d{6}Z$/
  @local_datetime_pattern ~r/^\d{8}T\d{6}$/
  @date_pattern ~r/^\d{8}$/

  # Should probably make this more robust
  @duration_pattern ~r/^P.*$/

  @gmt_offset_pattern ~r/^GMT(\+|\-)(\d{2})(\d{2})$/

  def decode!(data) do
    data
    |> decode_lines()
    |> decode_blocks()
  end

  defp decode_lines(bin) do
    bin
    |> String.splitter(["\r\n", "\n"])
    |> Enum.flat_map_reduce(nil, fn
      " " <> rest, acc ->
        {[], acc <> rest}

      line, prevline ->
        {(prevline && [String.replace(prevline, "\\n", "\n")]) || [], line}
    end)
    |> elem(0)
  end

  defp decode_blocks([]), do: []

  # decode each block as a list
  defp decode_blocks(["BEGIN:" <> binkey | rest]) do
    {props, [_ | lines_rest]} = Enum.split_while(rest, &(!match?("END:" <> ^binkey, &1)))
    key = decode_key(binkey)

    # accumulate block of same keys
    case decode_blocks(lines_rest) do
      [{^key, elems} | props_rest] -> [{key, [decode_blocks(props) | elems]} | props_rest]
      props_rest -> [{key, [decode_blocks(props)]} | props_rest]
    end
  end

  # recursive decoding if no BEGIN/END block
  defp decode_blocks([prop | rest]), do: [decode_prop(prop) | decode_blocks(rest)]

  # decode key,params and value for each prop
  defp decode_prop(prop) do
    case String.split(prop, ":", parts: 2) do
      [keyprops, val] ->
        case String.split(keyprops, ";") do
          ["DURATION"] ->
            {:duration, {Timex.Duration.parse!(val), []}}

          [key] ->
            {decode_key(key), {decode_value(val, []), []}}

          [key | props] ->
            props =
              props
              |> Enum.map(fn prop ->
                [k, v] =
                  case String.split(prop, "=") do
                    [k1, v1] ->
                      [k1, v1]

                    [k1 | tl] ->
                      # This case handles malformed X-APPLE-STRUCTURED-LOCATION
                      # properties that fail to quote-escape `=` characters.
                      [k1, Enum.join(tl, "=")]
                  end

                {decode_key(k), v}
              end)

            {decode_key(key), {decode_value(val, props), props}}
        end

      prop ->
        raise DecodeError, message: "property has no value: #{inspect(prop)}"
    end
  end

  defp decode_value(val, props) do
    time_zone = Keyword.get(props, :tzid)

    cond do
      String.match?(val, @local_datetime_pattern) ->
        decode_local_datetime(val, time_zone)

      String.match?(val, @utc_datetime_pattern) ->
        decode_utc_datetime(val)

      String.match?(val, @date_pattern) && Keyword.get(props, :value) == "DATE" ->
        decode_date(val)

      String.match?(val, @duration_pattern) && Keyword.get(props, :value) == "DURATION" ->
        decode_duration(val)

      true ->
        val
    end
  end

  defp decode_local_datetime(val, time_zone) do
    naive_datetime = Timex.parse!(val, "{YYYY}{0M}{0D}T{h24}{m}{s}")

    if time_zone do
      case Regex.run(@gmt_offset_pattern, time_zone) do
        [_, "-", hour, min] ->
          naive_datetime
          |> DateTime.from_naive!("Etc/UTC")
          |> Timex.add(String.to_integer(hour) |> Timex.Duration.from_hours())
          |> Timex.add(String.to_integer(min) |> Timex.Duration.from_minutes())
          |> DateTime.truncate(:second)

        [_, "+", hour, min] ->
          naive_datetime
          |> DateTime.from_naive!("Etc/UTC")
          |> Timex.subtract(String.to_integer(hour) |> Timex.Duration.from_hours())
          |> Timex.subtract(String.to_integer(min) |> Timex.Duration.from_minutes())
          |> DateTime.truncate(:second)

        _ ->
          if !Enum.member?(Tzdata.zone_list(), time_zone) do
            raise InvalidTimeZoneError,
              message: "#{time_zone} is not a valid time zone identifier"
          end

          naive_datetime
          |> DateTime.from_naive!(time_zone)
          |> DateTime.truncate(:second)
      end
    else
      naive_datetime
    end
  end

  defp decode_utc_datetime(val) do
    val
    |> Timex.parse!("{YYYY}{0M}{0D}T{h24}{m}{s}Z")
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.truncate(:second)
  end

  defp decode_date(val) do
    val
    |> Timex.parse!("{YYYY}{0M}{0D}")
    |> NaiveDateTime.to_date()
  end

  defp decode_key(bin) do
    bin
    |> String.replace("-", "_")
    |> String.downcase()
    |> String.slice(0..254)
    |> String.to_atom()
  end

  defp decode_duration(val) do
    case Timex.Duration.parse(val) do
      {:ok, duration} -> duration
      _ -> val
    end
  end
end
