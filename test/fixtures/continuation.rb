# frozen_string_literal: true

# A hash literal over several lines. Ruby counts the line of the first entry and
# reports nil for the line of the second.
class Continuation
  def self.summary(counts)
    {
      yes: counts.fetch(true, 0),
      no: counts.fetch(false, 0)
    }
  end
end
