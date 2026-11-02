# frozen_string_literal: true

Puppet::Type.newtype(:checkmk_status) do
  @doc = 'Evaluates and logs a Checkmk bootstrap result without generating a change event.'

  newparam(:name, namevar: true) do
    desc 'A label for the bootstrap operation.'
  end

  newproperty(:message) do
    desc 'The result of a deferred bootstrap function. This is status, not managed state.'

    def retrieve
      # Puppet resolves Deferred values before retrieving this property. Return
      # that result as current state so logging it does not count as a change.
      result = should
      @resource.debug(@sensitive ? 'Sensitive [value redacted]' : result)
      result
    end
  end
end
