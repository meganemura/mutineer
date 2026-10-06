# frozen_string_literal: true

module Mutineer
  # The cause of the exception that ended a forked child, sent to the parent
  # through a pipe. The exit status (2) says only that the child raised.
  #
  # Stdlib only, so a process without the rest of mutineer can load it.
  module ChildError
    # Backtrace lines kept after the first line of the cause.
    BACKTRACE_LINES = 5

    # Bytes kept. Smaller than any pipe buffer, so the child's write never
    # waits for the parent, which reads only after the child has ended.
    LIMIT = 4096

    # The cause as valid UTF-8 text of at most {LIMIT} bytes. A StandardError
    # while reading the exception gives a fixed text instead.
    #
    # @param error [Exception] the exception that ended the child.
    # @return [String] the class and message, then up to {BACKTRACE_LINES} lines.
    def self.describe(error)
      lines = ["#{error.class}: #{message_of(error)}", *Array(error.backtrace).first(BACKTRACE_LINES)]
      # Each line on its own: a binary message and a UTF-8 path cannot be joined.
      text = lines.map { |line| line.to_s.dup.force_encoding(Encoding::UTF_8).scrub }.join("\n")
      # A cut can split a character; drop its remaining bytes, not replace them.
      text.byteslice(0, LIMIT).scrub("")
    rescue StandardError
      "(the cause could not be described)"
    end

    # The exception's message, or a note when reading it raises.
    #
    # @param error [Exception]
    # @return [String]
    def self.message_of(error)
      error.message
    rescue StandardError => e
      "(reading the message raised #{e.class})"
    end

    # Writes the cause to `io`. A failed write is ignored: the child is about
    # to exit, and stderr already holds the first line.
    #
    # @param io [IO] the pipe's write end.
    # @param cause [String] the text from {.describe}.
    # @return [void]
    def self.write(io, cause)
      io.write(cause)
    rescue StandardError
      nil
    end

    # Reads what the child wrote, without waiting: a grandchild that the
    # child left running can hold the write end open.
    #
    # @param io [IO] the pipe's read end.
    # @return [String, nil] the cause, or nil when the child wrote none.
    def self.read(io)
      text = io.read_nonblock(LIMIT, exception: false)
      return unless text.is_a?(String) && !text.empty?

      text.force_encoding(Encoding::UTF_8).scrub
    end
  end
end
